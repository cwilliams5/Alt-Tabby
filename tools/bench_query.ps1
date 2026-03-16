# bench_query.ps1 - Benchmark all query tools
#
# Runs each query tool with representative arguments, captures both
# external (wall clock) and internal (tool-reported) timing.
# Used by /review-tool-speed to establish baselines and measure impact.
#
# Usage:
#   powershell -File tools/bench_query.ps1              (3 iterations, all tools)
#   powershell -File tools/bench_query.ps1 -Iterations 5
#   powershell -File tools/bench_query.ps1 -InternalOnly

param(
    [int]$Iterations = 3,
    [switch]$InternalOnly
)

$ErrorActionPreference = 'Stop'

# === Curated test table: representative args that exercise main code paths ===
# Add new query tools here when created
$benchmarks = @(
    @{ Tool = 'query_config.ps1';               Args = @() },
    @{ Tool = 'query_state.ps1';                Args = @('ACTIVE', 'TAB_STEP') },
    @{ Tool = 'query_events.ps1';               Args = @('focus') },
    @{ Tool = 'query_function.ps1';             Args = @('GUI_Repaint') },
    @{ Tool = 'query_callchain.ps1';            Args = @('GUI_Repaint') },
    @{ Tool = 'query_function_visibility.ps1';  Args = @('GUI_Repaint') },
    @{ Tool = 'query_global_ownership.ps1';     Args = @('gGUI_State') },
    @{ Tool = 'query_impact.ps1';               Args = @('GUI_Repaint') },
    @{ Tool = 'query_mutations.ps1';            Args = @('gGUI_State') },
    @{ Tool = 'query_visibility.ps1';           Args = @() },
    @{ Tool = 'query_interface.ps1';            Args = @('gui_state.ahk') },
    @{ Tool = 'query_timers.ps1';               Args = @() },
    @{ Tool = 'query_includes.ps1';             Args = @('gui_state.ahk') },
    @{ Tool = 'query_ipc.ps1';                  Args = @('IPC_MSG_SNAPSHOT') },
    @{ Tool = 'query_messages.ps1';             Args = @('0x0312') },
    @{ Tool = 'query_instrumentation.ps1';      Args = @() },
    @{ Tool = 'query_shader.ps1';               Args = @() }
)

$rxCompleted = [regex]::new('Completed in (\d+)ms')
$rxPass = [regex]::new('pass1:\s*(\d+)ms.*pass2:\s*(\d+)ms')

# === Coverage check: detect stale table vs actual query_*.ps1 files ===
$knownTools = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($b in $benchmarks) { [void]$knownTools.Add($b.Tool) }

$actualFiles = Get-ChildItem $PSScriptRoot -Filter "query_*.ps1" | ForEach-Object { $_.Name }
$coverageWarnings = $false

foreach ($f in $actualFiles) {
    if (-not $knownTools.Contains($f)) {
        if (-not $coverageWarnings) { Write-Host ""; $coverageWarnings = $true }
        Write-Host "  NOTE: Uncovered query tool '$f' - add to benchmark table?" -ForegroundColor Yellow
    }
}
foreach ($b in $benchmarks) {
    if (-not (Test-Path (Join-Path $PSScriptRoot $b.Tool))) {
        if (-not $coverageWarnings) { Write-Host ""; $coverageWarnings = $true }
        Write-Host "  NOTE: Expected query tool '$($b.Tool)' missing - remove from benchmark table?" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "  === Query Tool Benchmark ($Iterations iterations) ===" -ForegroundColor Cyan
Write-Host ""

$results = [System.Collections.ArrayList]::new()

foreach ($bench in $benchmarks) {
    $script = Join-Path $PSScriptRoot $bench.Tool
    if (-not (Test-Path $script)) {
        Write-Host "  SKIP $($bench.Tool) - not found" -ForegroundColor Red
        continue
    }

    $argLabel = if ($bench.Args.Count -gt 0) { " " + ($bench.Args -join ' ') } else { "" }
    $label = "$($bench.Tool)$argLabel"
    Write-Host "  $label..." -NoNewline -ForegroundColor White

    $externalTimes = @()
    $internalTimes = @()
    $passDetails = ""

    for ($r = 0; $r -lt $Iterations; $r++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        if ($bench.Args.Count -gt 0) {
            $output = & powershell -NoProfile -File $script @($bench.Args) 2>&1 | Out-String
        } else {
            $output = & powershell -NoProfile -File $script 2>&1 | Out-String
        }
        $sw.Stop()
        $externalTimes += $sw.ElapsedMilliseconds

        $m = $rxCompleted.Match($output)
        if ($m.Success) {
            $internalTimes += [int]$m.Groups[1].Value
        }

        # Capture pass details from last run
        if ($r -eq $Iterations - 1) {
            $pm = $rxPass.Match($output)
            if ($pm.Success) {
                $passDetails = " (p1: $($pm.Groups[1].Value)ms, p2: $($pm.Groups[2].Value)ms)"
            }
        }
    }

    # Report median (middle value of sorted array)
    $sortedExt = $externalTimes | Sort-Object
    $medianIdx = [math]::Floor($Iterations / 2)
    $extMedian = $sortedExt[$medianIdx]

    if ($InternalOnly) {
        if ($internalTimes.Count -eq $Iterations) {
            $sortedInt = $internalTimes | Sort-Object
            $intMedian = $sortedInt[$medianIdx]
            Write-Host " ${intMedian}ms${passDetails}" -ForegroundColor Green
        } else {
            Write-Host " (no internal timing)" -ForegroundColor DarkGray
        }
    } else {
        $intStr = ""
        if ($internalTimes.Count -eq $Iterations) {
            $sortedInt = $internalTimes | Sort-Object
            $intMedian = $sortedInt[$medianIdx]
            $intStr = "  internal: ${intMedian}ms${passDetails}"
        }
        Write-Host " ${extMedian}ms${intStr}" -ForegroundColor Green
    }

    [void]$results.Add(@{
        Label = $label
        ExtMedian = $extMedian
        IntMedian = if ($internalTimes.Count -eq $Iterations) { ($internalTimes | Sort-Object)[$medianIdx] } else { -1 }
        PassDetails = $passDetails
    })
}

# Summary table
Write-Host ""
Write-Host "  === Summary (median of $Iterations runs) ===" -ForegroundColor Cyan

if ($InternalOnly) {
    Write-Host "  $("Tool".PadRight(50)) $("Internal".PadLeft(10))" -ForegroundColor White
    Write-Host "  $("-" * 62)" -ForegroundColor DarkGray
    foreach ($r in $results) {
        $intStr = if ($r.IntMedian -ge 0) { "$($r.IntMedian)ms" } else { "n/a" }
        $color = if ($r.IntMedian -gt 800) { "Yellow" } elseif ($r.IntMedian -gt 400) { "White" } else { "Green" }
        Write-Host "  $($r.Label.PadRight(50)) $($intStr.PadLeft(10))" -ForegroundColor $color
    }
} else {
    Write-Host "  $("Tool".PadRight(50)) $("External".PadLeft(10))  $("Internal".PadLeft(10))" -ForegroundColor White
    Write-Host "  $("-" * 74)" -ForegroundColor DarkGray
    foreach ($r in $results) {
        $intStr = if ($r.IntMedian -ge 0) { "$($r.IntMedian)ms" } else { "n/a" }
        $color = if ($r.IntMedian -gt 800) { "Yellow" } elseif ($r.IntMedian -gt 400) { "White" } else { "Green" }
        Write-Host "  $($r.Label.PadRight(50)) $("$($r.ExtMedian)ms".PadLeft(10))  $($intStr.PadLeft(10))" -ForegroundColor $color
    }
}

Write-Host ""
