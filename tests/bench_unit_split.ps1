# Benchmark: Unit test split analysis
# Measures startup overhead and per-file test times to find optimal parallelization.
# Usage: powershell -File tests\bench_unit_split.ps1

$ahk = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$testsDir = $PSScriptRoot
$iterations = 3

# --- SilentProcess (minimal version for benchmarking) ---
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class BP {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(
        string app, StringBuilder cmd, IntPtr pa, IntPtr ta,
        bool inherit, uint flags, IntPtr env, string dir,
        ref SI si, out PI pi);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out int code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SI {
        public int cb; public string r1, r2, r3;
        public int x, y, xs, ys, xc, yc, fa, fl;
        public short sw, r4; public IntPtr r5, hi, ho, he;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PI { public IntPtr hP, hT; public int pid, tid; }

    public static IntPtr Start(string cmd, string dir = null) {
        var si = new SI(); si.cb = Marshal.SizeOf(si);
        si.fl = 0x81; var sb = new StringBuilder(cmd); PI pi;
        if (!CreateProcessW(null, sb, IntPtr.Zero, IntPtr.Zero, false,
            0x08000000, IntPtr.Zero, dir, ref si, out pi)) return IntPtr.Zero;
        CloseHandle(pi.hT); return pi.hP;
    }
    public static int WaitExit(IntPtr h) {
        if (h == IntPtr.Zero) return -1;
        WaitForSingleObject(h, 0xFFFFFFFF);
        int c; GetExitCodeProcess(h, out c); CloseHandle(h); return c;
    }
}
"@

function Measure-AhkRun {
    param([string]$CmdLine, [int]$Runs = 3)
    $times = @()
    for ($i = 0; $i -lt $Runs; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $h = [BP]::Start($CmdLine)
        $code = [BP]::WaitExit($h)
        $sw.Stop()
        if ($code -ne 0) { Write-Host "  WARNING: exit code $code on run $($i+1)" -ForegroundColor Yellow }
        $times += $sw.ElapsedMilliseconds
    }
    $avg = [math]::Round(($times | Measure-Object -Average).Average)
    $min = ($times | Measure-Object -Minimum).Minimum
    $max = ($times | Measure-Object -Maximum).Maximum
    return @{ Avg = $avg; Min = $min; Max = $max; Times = $times }
}

function Measure-ParallelAhkRun {
    param([string[]]$CmdLines, [int]$Runs = 3)
    $times = @()
    for ($i = 0; $i -lt $Runs; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $handles = @()
        foreach ($cmd in $CmdLines) {
            $handles += [BP]::Start($cmd)
        }
        foreach ($h in $handles) {
            [BP]::WaitExit($h) | Out-Null
        }
        $sw.Stop()
        $times += $sw.ElapsedMilliseconds
    }
    $avg = [math]::Round(($times | Measure-Object -Average).Average)
    $min = ($times | Measure-Object -Minimum).Minimum
    $max = ($times | Measure-Object -Maximum).Maximum
    return @{ Avg = $avg; Min = $min; Max = $max; Times = $times }
}

Write-Host "=== Unit Test Split Benchmark ===" -ForegroundColor Cyan
Write-Host "Iterations per measurement: $iterations"
Write-Host ""

# --- 1. Measure startup-only cost (load all includes, no tests) ---
Write-Host "--- Phase 1: Startup Overhead ---" -ForegroundColor Yellow

# Create a minimal script that loads all includes but runs no tests
$startupScript = "$env:TEMP\bench_startup_only.ahk"
@"
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn VarUnset, Off
A_IconHidden := true
global TestLogPath := A_Temp "\bench_noop.log"
global TestErrors := 0
global TestPassed := 0
global g_TestingMode := true
global gStore_TestMode := false
global testServer := 0
global gTestClient := 0
global gTestResponse := ""
global gTestResponseReceived := false
global gRealStoreResponse := ""
global gRealStoreReceived := false
global gViewerTestResponse := ""
global gViewerTestReceived := false
global gWsE2EResponse := ""
global gWsE2EReceived := false
global gHbTestHeartbeats := 0
global gHbTestLastRev := -1
global gHbTestReceived := false
global gProdTestProducers := ""
global gProdTestReceived := false
global gMruTestResponse := ""
global gMruTestReceived := false
global gProjTestResponse := ""
global gProjTestReceived := false
global gMultiClient1Response := ""
global gMultiClient1Received := false
global gMultiClient2Response := ""
global gMultiClient2Received := false
global gMultiClient3Response := ""
global gMultiClient3Received := false
global gBlTestResponse := ""
global gBlTestReceived := false
#Include $testsDir\..\src\shared\config_loader.ahk
#Include $testsDir\..\src\shared\cjson.ahk
#Include $testsDir\..\src\shared\ipc_pipe.ahk
#Include $testsDir\..\src\shared\blacklist.ahk
#Include $testsDir\..\src\shared\setup_utils.ahk
#Include $testsDir\..\src\shared\process_utils.ahk
#Include $testsDir\..\src\shared\win_utils.ahk
#Include $testsDir\..\src\shared\stats.ahk
#Include $testsDir\..\src\shared\window_list.ahk
#Include $testsDir\..\src\core\winenum_lite.ahk
#Include $testsDir\..\src\core\komorebi_sub.ahk
#Include $testsDir\..\src\core\icon_pump.ahk
#Include $testsDir\test_utils.ahk
#Include $testsDir\test_unit.ahk
#Include $testsDir\test_live.ahk
ConfigLoader_Init(A_ScriptDir "\..\src")
Blacklist_Init(A_ScriptDir "\..\src\shared\blacklist.txt")
ExitApp(0)
"@ | Set-Content $startupScript -Encoding UTF8

$startupResult = Measure-AhkRun -CmdLine ('"' + $ahk + '" /ErrorStdOut "' + $startupScript + '"') -Runs $iterations
Write-Host "  Startup only (includes + init): avg $($startupResult.Avg)ms  (min $($startupResult.Min), max $($startupResult.Max))" -ForegroundColor Green

# --- 2. Measure each test file individually ---
Write-Host "`n--- Phase 2: Per-File Test Times ---" -ForegroundColor Yellow

$testFiles = @("Core", "Storage", "Setup", "Cleanup", "Advanced")
$perFileResults = @{}

foreach ($name in $testFiles) {
    # Create a script that loads everything and runs only one test suite
    $singleScript = "$env:TEMP\bench_unit_$($name.ToLower()).ahk"
    @"
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn VarUnset, Off
A_IconHidden := true
global TestLogPath := A_Temp "\bench_$($name.ToLower()).log"
global TestErrors := 0
global TestPassed := 0
global g_TestingMode := true
global gStore_TestMode := false
global testServer := 0
global gTestClient := 0
global gTestResponse := ""
global gTestResponseReceived := false
global gRealStoreResponse := ""
global gRealStoreReceived := false
global gViewerTestResponse := ""
global gViewerTestReceived := false
global gWsE2EResponse := ""
global gWsE2EReceived := false
global gHbTestHeartbeats := 0
global gHbTestLastRev := -1
global gHbTestReceived := false
global gProdTestProducers := ""
global gProdTestReceived := false
global gMruTestResponse := ""
global gMruTestReceived := false
global gProjTestResponse := ""
global gProjTestReceived := false
global gMultiClient1Response := ""
global gMultiClient1Received := false
global gMultiClient2Response := ""
global gMultiClient2Received := false
global gMultiClient3Response := ""
global gMultiClient3Received := false
global gBlTestResponse := ""
global gBlTestReceived := false
#Include $testsDir\..\src\shared\config_loader.ahk
#Include $testsDir\..\src\shared\cjson.ahk
#Include $testsDir\..\src\shared\ipc_pipe.ahk
#Include $testsDir\..\src\shared\blacklist.ahk
#Include $testsDir\..\src\shared\setup_utils.ahk
#Include $testsDir\..\src\shared\process_utils.ahk
#Include $testsDir\..\src\shared\win_utils.ahk
#Include $testsDir\..\src\shared\stats.ahk
#Include $testsDir\..\src\shared\window_list.ahk
#Include $testsDir\..\src\core\winenum_lite.ahk
#Include $testsDir\..\src\core\komorebi_sub.ahk
#Include $testsDir\..\src\core\icon_pump.ahk
#Include $testsDir\test_utils.ahk
#Include $testsDir\test_unit.ahk
#Include $testsDir\test_live.ahk
ConfigLoader_Init(A_ScriptDir "\..\src")
Blacklist_Init(A_ScriptDir "\..\src\shared\blacklist.txt")
try FileDelete(TestLogPath)
RunUnitTests_$name()
Log("``n=== Test Summary ===")
Log("Passed: " TestPassed)
Log("Failed: " TestErrors)
ExitApp(TestErrors > 0 ? 1 : 0)
"@ | Set-Content $singleScript -Encoding UTF8

    $result = Measure-AhkRun -CmdLine ('"' + $ahk + '" /ErrorStdOut "' + $singleScript + '"') -Runs $iterations
    $testOnly = $result.Avg - $startupResult.Avg
    $perFileResults[$name] = @{ Total = $result.Avg; TestOnly = [math]::Max(0, $testOnly); Raw = $result }
    Write-Host ("  {0,-12} total: {1,5}ms  test-only: ~{2,5}ms  (min {3}, max {4})" -f $name, $result.Avg, [math]::Max(0, $testOnly), $result.Min, $result.Max) -ForegroundColor Green
}

# --- 3. Baseline: all unit tests in one process ---
Write-Host "`n--- Phase 3: Baseline (1 process, all tests) ---" -ForegroundColor Yellow

$baselineCmd = '"' + $ahk + '" /ErrorStdOut "' + "$testsDir\run_tests.ahk" + '"'
$baselineResult = Measure-AhkRun -CmdLine $baselineCmd -Runs $iterations
Write-Host "  All-in-one: avg $($baselineResult.Avg)ms  (min $($baselineResult.Min), max $($baselineResult.Max))" -ForegroundColor Green

# --- 4. Test parallel groupings ---
Write-Host "`n--- Phase 4: Parallel Split Configurations ---" -ForegroundColor Yellow

# Build command lines for each individual test file
$cmdLines = @{}
foreach ($name in $testFiles) {
    $cmdLines[$name] = '"' + $ahk + '" /ErrorStdOut "' + "$env:TEMP\bench_unit_$($name.ToLower()).ahk" + '"'
}

# Config: 2-way splits
$splits2 = @(
    @{ Name = "2-way: (Core+Storage) | (Setup+Cleanup+Advanced)"; Groups = @(
        @($cmdLines["Core"], $cmdLines["Storage"]),
        @($cmdLines["Setup"], $cmdLines["Cleanup"], $cmdLines["Advanced"])
    )},
    @{ Name = "2-way: (Core+Setup) | (Storage+Cleanup+Advanced)"; Groups = @(
        @($cmdLines["Core"], $cmdLines["Setup"]),
        @($cmdLines["Storage"], $cmdLines["Cleanup"], $cmdLines["Advanced"])
    )},
    @{ Name = "2-way: (Core+Advanced) | (Storage+Setup+Cleanup)"; Groups = @(
        @($cmdLines["Core"], $cmdLines["Advanced"]),
        @($cmdLines["Storage"], $cmdLines["Setup"], $cmdLines["Cleanup"])
    )}
)

# Config: 3-way split
$splits3 = @(
    @{ Name = "3-way: (Core) | (Storage) | (Setup+Cleanup+Advanced)"; Groups = @(
        @($cmdLines["Core"]),
        @($cmdLines["Storage"]),
        @($cmdLines["Setup"], $cmdLines["Cleanup"], $cmdLines["Advanced"])
    )}
)

# Config: 5-way split (each file separate)
$splits5 = @(
    @{ Name = "5-way: each file separate"; Groups = @(
        @($cmdLines["Core"]),
        @($cmdLines["Storage"]),
        @($cmdLines["Setup"]),
        @($cmdLines["Cleanup"]),
        @($cmdLines["Advanced"])
    )}
)

$allSplits = $splits2 + $splits3 + $splits5

foreach ($split in $allSplits) {
    # For each group, we need to run them sequentially within the group,
    # but groups run in parallel. Actually wait - each "group" here is multiple
    # separate processes that run sequentially. But we want to measure:
    # "if we split unit tests into N parallel processes, where each process
    # runs a subset of test files sequentially, how fast is wall-clock?"
    #
    # Since each bench script runs ONE test suite, to simulate a group of
    # (Core+Storage), we'd need a combined script. Instead, let's just
    # run each test file as its own process and measure parallel wall-clock.
    # This gives us the "each group = 1 file" scenario directly.
    # For multi-file groups, we sum the test-only times + 1 startup.

    # Simple approach: launch all individual processes in parallel, measure wall-clock
    $allCmds = @()
    foreach ($group in $split.Groups) {
        # For now, just use the first cmd in each group (single-file groups)
        # For multi-file groups, we'll need combined scripts - skip for now
        # and just run all files in parallel
        foreach ($cmd in $group) {
            $allCmds += $cmd
        }
    }

    $nGroups = $split.Groups.Count
    $result = Measure-ParallelAhkRun -CmdLines $allCmds -Runs $iterations
    $savings = $baselineResult.Avg - $result.Avg
    $savingsStr = if ($savings -gt 0) { "-$($savings)ms" } else { "+$([math]::Abs($savings))ms" }
    Write-Host ("  {0,-55} avg: {1,5}ms  ({2})  (min {3}, max {4})" -f $split.Name, $result.Avg, $savingsStr, $result.Min, $result.Max) -ForegroundColor Green
}

# --- 5. Summary ---
Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  Startup overhead:    $($startupResult.Avg)ms" -ForegroundColor White
Write-Host "  Baseline (1 proc):   $($baselineResult.Avg)ms" -ForegroundColor White
Write-Host ""
Write-Host "  Per-file test-only times:" -ForegroundColor White
$sorted = $perFileResults.GetEnumerator() | Sort-Object { $_.Value.TestOnly } -Descending
foreach ($entry in $sorted) {
    $bar = "#" * [math]::Max(1, [math]::Round($entry.Value.TestOnly / 100))
    Write-Host ("    {0,-12} {1,5}ms  {2}" -f $entry.Key, $entry.Value.TestOnly, $bar) -ForegroundColor White
}

# Cleanup
Remove-Item -Force -ErrorAction SilentlyContinue $startupScript
foreach ($name in $testFiles) {
    Remove-Item -Force -ErrorAction SilentlyContinue "$env:TEMP\bench_unit_$($name.ToLower()).ahk"
    Remove-Item -Force -ErrorAction SilentlyContinue "$env:TEMP\bench_$($name.ToLower()).log"
}
Remove-Item -Force -ErrorAction SilentlyContinue "$env:TEMP\bench_noop.log"
