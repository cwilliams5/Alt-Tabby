# bench_query.ps1 - Benchmark query tools
#
# Runs each of the slowest query tools 3 times, captures "Completed in Xms"
# from output, and reports min/avg/max.
#
# Usage:
#   powershell -File tools/bench_query.ps1

param(
    [int]$Iterations = 3
)

$ErrorActionPreference = 'Stop'

# Define the benchmark targets with representative arguments
$benchmarks = @(
    @{ Name = "query_visibility";           Cmd = "powershell -File `"$PSScriptRoot\query_visibility.ps1`"" }
    @{ Name = "query_callchain";            Cmd = "powershell -File `"$PSScriptRoot\query_callchain.ps1`" GUI_Repaint" }
    @{ Name = "query_impact";               Cmd = "powershell -File `"$PSScriptRoot\query_impact.ps1`" GUI_Repaint" }
    @{ Name = "query_function_visibility";  Cmd = "powershell -File `"$PSScriptRoot\query_function_visibility.ps1`" -Discover" }
    @{ Name = "query_timers";               Cmd = "powershell -File `"$PSScriptRoot\query_timers.ps1`"" }
    @{ Name = "query_messages";             Cmd = "powershell -File `"$PSScriptRoot\query_messages.ps1`"" }
)

# Extract milliseconds from "Completed in Xms" output
$rxCompleted = [regex]::new('Completed in (\d+)ms')

Write-Host ""
Write-Host "  === Query Tool Benchmark ($Iterations iterations) ===" -ForegroundColor Cyan
Write-Host ""

$results = @()

foreach ($bench in $benchmarks) {
    $times = @()
    Write-Host "  $($bench.Name)..." -NoNewline -ForegroundColor White

    for ($i = 0; $i -lt $Iterations; $i++) {
        $output = & cmd /c $bench.Cmd 2>&1 | Out-String
        $m = $rxCompleted.Match($output)
        if ($m.Success) {
            $times += [int]$m.Groups[1].Value
        } else {
            Write-Host " ERROR (no timing in output)" -ForegroundColor Red
            Write-Host $output -ForegroundColor DarkGray
            break
        }
    }

    if ($times.Count -eq $Iterations) {
        $min = ($times | Measure-Object -Minimum).Minimum
        $max = ($times | Measure-Object -Maximum).Maximum
        $avg = [math]::Round(($times | Measure-Object -Average).Average)
        Write-Host " min=$($min)ms  avg=$($avg)ms  max=$($max)ms" -ForegroundColor Green
        $results += @{ Name = $bench.Name; Min = $min; Avg = $avg; Max = $max; Times = $times }
    }
}

# Summary table
Write-Host ""
Write-Host "  === Summary ===" -ForegroundColor Cyan
Write-Host "  $("Tool".PadRight(32)) $("Min".PadLeft(6))  $("Avg".PadLeft(6))  $("Max".PadLeft(6))" -ForegroundColor White
Write-Host "  $("-" * 58)" -ForegroundColor DarkGray

foreach ($r in $results) {
    $color = if ($r.Avg -gt 1000) { "Yellow" } elseif ($r.Avg -gt 500) { "White" } else { "Green" }
    Write-Host "  $($r.Name.PadRight(32)) $("$($r.Min)ms".PadLeft(6))  $("$($r.Avg)ms".PadLeft(6))  $("$($r.Max)ms".PadLeft(6))" -ForegroundColor $color
}
Write-Host ""
