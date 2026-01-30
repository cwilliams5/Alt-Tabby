# Alt-Tabby Test Runner
# Usage: .\tests\test.ps1 [--live] [--force-compile] [--timing]

param(
    [switch]$live,
    [Alias("force-compile")]
    [switch]$forceCompile,
    [switch]$timing,
    [Parameter(ValueFromRemainingArguments=$true)]
    $remainingArgs
)

# HARDENING: Detect when called incorrectly via `powershell -Command`
# With -Command, switch params aren't parsed correctly and end up in $remainingArgs
# This MUST fail hard - warnings get ignored by LLM agents
if ($remainingArgs) {
    foreach ($arg in $remainingArgs) {
        if ($arg -match '^-{1,2}(live|force-?compile|timing)$') {
            Write-Host ""
            Write-Host "============================================================" -ForegroundColor Red
            Write-Host "FATAL FAILURE: Do NOT use 'powershell -Command'" -ForegroundColor Red
            Write-Host "============================================================" -ForegroundColor Red
            Write-Host ""
            Write-Host "WRONG: powershell -Command `".\tests\test.ps1 --live`"" -ForegroundColor Red
            Write-Host "RIGHT: .\tests\test.ps1 --live" -ForegroundColor Green
            Write-Host "RIGHT: powershell -File .\tests\test.ps1 --live" -ForegroundColor Green
            Write-Host ""
            Write-Host "The -Command flag breaks argument parsing. Use -File or direct invocation." -ForegroundColor Yellow
            Write-Host "============================================================" -ForegroundColor Red
            exit 1
        }
    }
}

# --- Timing Infrastructure ---
$masterSw = [System.Diagnostics.Stopwatch]::StartNew()
$timingEvents = [System.Collections.ArrayList]::new()

function Record-PhaseStart {
    param([string]$Name)
    if (-not $script:timing) { return }
    [void]$script:timingEvents.Add(@{
        Type    = "phase_start"
        Name    = $Name
        TickMs  = $script:masterSw.ElapsedMilliseconds
    })
}

function Record-PhaseEnd {
    param([string]$Name)
    if (-not $script:timing) { return }
    [void]$script:timingEvents.Add(@{
        Type    = "phase_end"
        Name    = $Name
        TickMs  = $script:masterSw.ElapsedMilliseconds
    })
}

function Record-ItemTiming {
    param([string]$Phase, [string]$Item, [double]$DurationMs)
    if (-not $script:timing) { return }
    [void]$script:timingEvents.Add(@{
        Type       = "item"
        Phase      = $Phase
        Item       = $Item
        DurationMs = $DurationMs
    })
}

function Show-TimingReport {
    if (-not $script:timing) { return }

    $phases = [System.Collections.ArrayList]::new()
    $phaseStarts = @{}

    foreach ($ev in $script:timingEvents) {
        switch ($ev.Type) {
            "phase_start" { $phaseStarts[$ev.Name] = $ev.TickMs }
            "phase_end" {
                $startMs = if ($phaseStarts.ContainsKey($ev.Name)) { $phaseStarts[$ev.Name] } else { 0 }
                [void]$phases.Add(@{
                    Name       = $ev.Name
                    OffsetMs   = $startMs
                    DurationMs = $ev.TickMs - $startMs
                })
            }
        }
    }

    # Collect items per phase
    $phaseItems = @{}
    foreach ($ev in $script:timingEvents) {
        if ($ev.Type -eq "item") {
            if (-not $phaseItems.ContainsKey($ev.Phase)) { $phaseItems[$ev.Phase] = [System.Collections.ArrayList]::new() }
            [void]$phaseItems[$ev.Phase].Add(@{ Item = $ev.Item; DurationMs = $ev.DurationMs })
        }
    }

    $totalMs = $script:masterSw.ElapsedMilliseconds

    # Find bottleneck phase (longest duration)
    $bottleneckMs = 0
    $bottleneckName = ""
    foreach ($ph in $phases) {
        if ($ph.DurationMs -gt $bottleneckMs) {
            $bottleneckMs = $ph.DurationMs
            $bottleneckName = $ph.Name
        }
    }

    Write-Host ""
    Write-Host "=== TIMING REPORT ===" -ForegroundColor Cyan
    Write-Host ("{0,-44} {1,8} {2,10}" -f "Phase", "Offset", "Duration") -ForegroundColor Cyan
    Write-Host ("-" * 64) -ForegroundColor DarkGray

    foreach ($ph in $phases) {
        $offsetStr = "+{0:F1}s" -f ($ph.OffsetMs / 1000)
        $durStr = "{0:F1}s" -f ($ph.DurationMs / 1000)
        $marker = if ($ph.Name -eq $bottleneckName -and $phases.Count -gt 1) { " << bottleneck" } else { "" }
        Write-Host ("{0,-44} {1,8} {2,10}{3}" -f $ph.Name, $offsetStr, $durStr, $marker)

        # Show sub-items sorted by duration descending
        if ($phaseItems.ContainsKey($ph.Name)) {
            $sorted = $phaseItems[$ph.Name] | Sort-Object { $_.DurationMs } -Descending
            $slowestMs = $sorted[0].DurationMs
            foreach ($item in $sorted) {
                $itemDurStr = "{0:F1}s" -f ($item.DurationMs / 1000)
                $itemMarker = if ($item.DurationMs -eq $slowestMs -and $sorted.Count -gt 1) { " << slowest" } else { "" }
                Write-Host ("  {0,-42} {1,8} {2,10}{3}" -f $item.Item, "", $itemDurStr, $itemMarker)
            }
        }
    }

    Write-Host ("-" * 64) -ForegroundColor DarkGray
    $totalStr = "{0:F1}s" -f ($totalMs / 1000)
    Write-Host ("{0,-44} {1,8} {2,10}" -f "Total wall-clock", "", $totalStr) -ForegroundColor Cyan
    Write-Host ""
}

# --- Silent Process Helper ---
# Uses CreateProcessW with STARTF_FORCEOFFFEEDBACK (0x80) to suppress the
# Windows "app starting" cursor (pointer+hourglass) during process launches.
# PowerShell's Start-Process doesn't expose this flag.
#
# StartCaptured/RunWaitCaptured launch processes DIRECTLY (no cmd.exe wrapper)
# with STARTF_USESTDHANDLES to redirect stdout+stderr to a file. This applies
# FORCEOFFFEEDBACK to the actual target process, not an intermediate cmd.exe
# whose children would still trigger cursor feedback.
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class SilentProcess {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(
        string lpApplicationName, StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
        bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment,
        string lpCurrentDirectory, ref STARTUPINFOW si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        ref SECURITY_ATTRIBUTES lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out int code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFOW {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute;
        public int dwFlags; public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public bool bInheritHandle; }

    static string NullIfEmpty(string s) { return string.IsNullOrEmpty(s) ? null : s; }
    static readonly IntPtr INVALID = new IntPtr(-1);

    static IntPtr OpenInheritable(string path, uint access, uint creation) {
        var sa = new SECURITY_ATTRIBUTES();
        sa.nLength = Marshal.SizeOf(sa);
        sa.bInheritHandle = true;
        return CreateFileW(path, access, 3, ref sa, creation, 0, IntPtr.Zero);
    }

    // Launch without stdio redirection. Cursor suppressed.
    public static int RunWait(string cmdLine, string workDir = null) {
        var si = new STARTUPINFOW();
        si.cb = Marshal.SizeOf(si);
        si.dwFlags = 0x81; // STARTF_USESHOWWINDOW | STARTF_FORCEOFFFEEDBACK
        var sb = new StringBuilder(cmdLine);
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, sb, IntPtr.Zero, IntPtr.Zero, false,
                0x08000000, IntPtr.Zero, NullIfEmpty(workDir), ref si, out pi))
            return -1;
        WaitForSingleObject(pi.hProcess, 0xFFFFFFFF);
        int code; GetExitCodeProcess(pi.hProcess, out code);
        CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
        return code;
    }

    // Launch without stdio redirection, return process handle. Cursor suppressed.
    public static IntPtr Start(string cmdLine, string workDir = null) {
        var si = new STARTUPINFOW();
        si.cb = Marshal.SizeOf(si);
        si.dwFlags = 0x81; // STARTF_USESHOWWINDOW | STARTF_FORCEOFFFEEDBACK
        var sb = new StringBuilder(cmdLine);
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, sb, IntPtr.Zero, IntPtr.Zero, false,
                0x08000000, IntPtr.Zero, NullIfEmpty(workDir), ref si, out pi))
            return IntPtr.Zero;
        CloseHandle(pi.hThread);
        return pi.hProcess;
    }

    // Launch with stdout+stderr captured to file, stdin from NUL. Cursor suppressed.
    // Applies FORCEOFFEEDBACK directly to the target process (no cmd.exe wrapper).
    public static IntPtr StartCaptured(string cmdLine, string outputPath, string workDir = null) {
        IntPtr hNul = OpenInheritable("NUL", 0x80000000, 3);  // GENERIC_READ, OPEN_EXISTING
        IntPtr hOut = OpenInheritable(outputPath, 0x40000000, 2); // GENERIC_WRITE, CREATE_ALWAYS
        if (hNul == INVALID || hOut == INVALID) {
            if (hNul != INVALID) CloseHandle(hNul);
            if (hOut != INVALID) CloseHandle(hOut);
            return IntPtr.Zero;
        }
        var si = new STARTUPINFOW();
        si.cb = Marshal.SizeOf(si);
        si.dwFlags = 0x181; // STARTF_USESHOWWINDOW | STARTF_FORCEOFFFEEDBACK | STARTF_USESTDHANDLES
        si.hStdInput = hNul;
        si.hStdOutput = hOut;
        si.hStdError = hOut;
        var sb = new StringBuilder(cmdLine);
        PROCESS_INFORMATION pi;
        bool ok = CreateProcessW(null, sb, IntPtr.Zero, IntPtr.Zero, true,
            0x08000000, IntPtr.Zero, NullIfEmpty(workDir), ref si, out pi);
        CloseHandle(hNul);
        CloseHandle(hOut);
        if (!ok) return IntPtr.Zero;
        CloseHandle(pi.hThread);
        return pi.hProcess;
    }

    // Launch with capture and wait for exit. Cursor suppressed.
    public static int RunWaitCaptured(string cmdLine, string outputPath, string workDir = null) {
        return WaitAndGetExitCode(StartCaptured(cmdLine, outputPath, workDir));
    }

    public static int WaitAndGetExitCode(IntPtr hProcess) {
        if (hProcess == IntPtr.Zero) return -1;
        WaitForSingleObject(hProcess, 0xFFFFFFFF);
        int code; GetExitCodeProcess(hProcess, out code);
        CloseHandle(hProcess);
        return code;
    }

    // Non-blocking exit code check. Returns -259 (STILL_ACTIVE) if running.
    public static int TryGetExitCode(IntPtr hProcess) {
        if (hProcess == IntPtr.Zero) return -1;
        uint result = WaitForSingleObject(hProcess, 0);
        if (result != 0) return -259;
        int code; GetExitCodeProcess(hProcess, out code);
        return code;
    }
}
"@

$ahk = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$script = "$PSScriptRoot\run_tests.ahk"
$logFile = "$env:TEMP\alt_tabby_tests.log"
$srcRoot = (Resolve-Path "$PSScriptRoot\..\src").Path

# --- Compact Test Summary ---
# Parses an AHK test log file and outputs only failures + a one-line summary.
# Full verbose logs remain in the temp files for manual inspection.
function Show-TestSummary {
    param(
        [string]$LogPath,
        [string]$Label
    )

    if (-not (Test-Path $LogPath)) {
        Write-Host "  ${Label}: Log not found - tests may have crashed" -ForegroundColor Red
        return
    }

    $lines = Get-Content $LogPath -ErrorAction SilentlyContinue
    if (-not $lines) {
        Write-Host "  ${Label}: Log is empty - tests may have crashed" -ForegroundColor Red
        return
    }

    $failures = @()
    $passed = -1
    $failed = -1

    foreach ($line in $lines) {
        if ($line -match '^FAIL:\s') {
            $failures += $line
        }
        elseif ($line -match '^Passed:\s*(\d+)') {
            $passed = [int]$Matches[1]
        }
        elseif ($line -match '^Failed:\s*(\d+)') {
            $failed = [int]$Matches[1]
        }
    }

    # Show failures inline
    if ($failures.Count -gt 0) {
        foreach ($f in $failures) {
            Write-Host "  $f" -ForegroundColor Red
        }
    }

    # Show summary line
    if ($passed -ge 0 -and $failed -ge 0) {
        $total = $passed + $failed
        if ($failed -eq 0) {
            Write-Host "  ${Label}: ${passed}/${total} passed [PASS]" -ForegroundColor Green
        } else {
            Write-Host "  ${Label}: ${passed}/${total} passed, ${failed} failed [FAIL]" -ForegroundColor Red
        }
    } else {
        # No summary found - test likely crashed before completing
        if ($failures.Count -gt 0) {
            Write-Host "  ${Label}: Crashed after $($failures.Count) failure(s)" -ForegroundColor Red
        } else {
            Write-Host "  ${Label}: No summary found (test may have crashed)" -ForegroundColor Red
        }
    }

    Write-Host "  Log: $LogPath" -ForegroundColor DarkGray
}

# Remove old logs
Remove-Item -Force -ErrorAction SilentlyContinue $logFile

Write-Host "=== Alt-Tabby Test Run $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Cyan
Write-Host "Log file: $logFile"

# --- Syntax Check Phase (Parallel) ---
Record-PhaseStart "Syntax Check"
Write-Host "`n--- Syntax Check Phase (Parallel) ---" -ForegroundColor Yellow

$filesToCheck = @(
    "$srcRoot\store\windowstore.ahk",
    "$srcRoot\store\store_server.ahk",
    "$srcRoot\store\winenum_lite.ahk",
    "$srcRoot\store\icon_pump.ahk",
    "$srcRoot\store\proc_pump.ahk",
    "$srcRoot\viewer\viewer.ahk",
    "$srcRoot\gui\gui_main.ahk",
    "$srcRoot\gui\gui_interceptor.ahk",
    "$srcRoot\gui\gui_state.ahk",
    "$srcRoot\gui\gui_store.ahk",
    "$srcRoot\gui\gui_workspace.ahk",
    "$srcRoot\gui\gui_paint.ahk",
    "$srcRoot\gui\gui_input.ahk",
    "$srcRoot\gui\gui_overlay.ahk",
    "$PSScriptRoot\gui_tests.ahk"
)

# Launch all syntax checks in parallel — direct AHK launch with captured output
$syntaxProcs = @()
foreach ($file in $filesToCheck) {
    if (Test-Path $file) {
        $shortName = Split-Path $file -Leaf
        $errFile = "$env:TEMP\ahk_syntax_$shortName.log"
        Remove-Item -Force -ErrorAction SilentlyContinue $errFile

        $cmdLine = '"' + $ahk + '" /ErrorStdOut /validate "' + $file + '"'
        $hProc = [SilentProcess]::StartCaptured($cmdLine, $errFile)
        $syntaxProcs += @{
            Handle = $hProc
            FileName = $shortName
            ErrFile = $errFile
        }
    }
}

# Wait for all syntax checks to complete and collect results
$syntaxPassed = 0
$syntaxFailed = 0
foreach ($sp in $syntaxProcs) {
    if ($sp.Handle -eq [IntPtr]::Zero) {
        Write-Host "  FAIL: $($sp.FileName) (failed to launch)" -ForegroundColor Red
        $syntaxFailed++
        continue
    }
    $exitCode = [SilentProcess]::WaitAndGetExitCode($sp.Handle)
    if ($exitCode -ne 0) {
        Write-Host "  FAIL: $($sp.FileName)" -ForegroundColor Red
        $errContent = if (Test-Path $sp.ErrFile) { Get-Content $sp.ErrFile -Raw -ErrorAction SilentlyContinue } else { "" }
        if ($errContent) { Write-Host "    $errContent" -ForegroundColor Red }
        $syntaxFailed++
    } else {
        $syntaxPassed++
    }
}

$syntaxTotal = $syntaxPassed + $syntaxFailed
Record-PhaseEnd "Syntax Check"
if ($syntaxFailed -gt 0) {
    Write-Host "  Syntax: $syntaxPassed/$syntaxTotal passed, $syntaxFailed failed [FAIL]" -ForegroundColor Red
    Show-TimingReport
    exit 1
} else {
    Write-Host "  Syntax: $syntaxTotal/$syntaxTotal passed [PASS]" -ForegroundColor Green
}

# --- Static Analysis Pre-Gate (Parallel) ---
# Runs all check_*.ps1 scripts in parallel via the dispatcher.
# Catches issues like undeclared globals that cause runtime popups or silent bugs.
# This MUST pass before any AHK process launches.
Record-PhaseStart "Static Analysis"
Write-Host "`n--- Static Analysis Pre-Gate ---" -ForegroundColor Yellow

$staticAnalysisScript = "$PSScriptRoot\static_analysis.ps1"
if (Test-Path $staticAnalysisScript) {
    $saArgs = @{ SourceDir = $srcRoot }
    if ($timing) { $saArgs.Timing = $true }
    & $staticAnalysisScript @saArgs
    $saExit = $LASTEXITCODE

    # Read per-check timing data if available
    $saTimingFile = "$env:TEMP\sa_timing.json"
    if ($timing -and (Test-Path $saTimingFile)) {
        $saTimingData = Get-Content $saTimingFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($saTimingData) {
            foreach ($entry in $saTimingData) {
                Record-ItemTiming -Phase "Static Analysis" -Item $entry.Name -DurationMs $entry.DurationMs
            }
        }
        Remove-Item -Force -ErrorAction SilentlyContinue $saTimingFile
    }

    Record-PhaseEnd "Static Analysis"

    if ($saExit -ne 0) {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host "  STATIC ANALYSIS FAILED - TEST SUITE BLOCKED" -ForegroundColor Red
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "  One or more static analysis checks failed." -ForegroundColor Yellow
        Write-Host "  Fix all reported issues before tests can run." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  No tests will run until all static analysis checks pass." -ForegroundColor Red
        Write-Host "============================================================" -ForegroundColor Red
        Show-TimingReport
        exit 1
    }
} else {
    Record-PhaseEnd "Static Analysis"
    Write-Host "  SKIP: static_analysis.ps1 not found" -ForegroundColor Yellow
}

# --- Compilation Phase ---
# When --live is specified, skip compilation here - Core tests include compile.bat testing
# which handles compilation. This avoids redundant compilation (~5-10s savings).
$compiler = "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe"
$ahkBase = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$srcFile = "$srcRoot\alt_tabby.ahk"
$releaseDir = (Resolve-Path "$PSScriptRoot\..").Path + "\release"
$outFile = "$releaseDir\AltTabby.exe"

# --- Start GUI Tests Early (Background) ---
# GUI tests have no dependencies on compilation or store, so run them in parallel
$guiScript = "$PSScriptRoot\gui_tests.ahk"
$guiLogFile = "$env:TEMP\gui_tests.log"
$guiHandle = [IntPtr]::Zero

Remove-Item -Force -ErrorAction SilentlyContinue $guiLogFile

if (Test-Path $guiScript) {
    Write-Host "Starting GUI tests in background..." -ForegroundColor Cyan
    Record-PhaseStart "GUI Tests (background)"
    $guiHandle = [SilentProcess]::Start('"' + $ahk + '" /ErrorStdOut "' + $guiScript + '"')
}

if ($live) {
    Record-PhaseStart "Compilation"
    Write-Host "`n--- Compilation Phase (compile.bat) ---" -ForegroundColor Yellow
    $compileBat = (Resolve-Path "$PSScriptRoot\..").Path + "\compile.bat"
    $compileDir = (Resolve-Path "$PSScriptRoot\..").Path

    if (Test-Path $compileBat) {
        # Kill running AltTabby processes first
        $running = Get-Process -Name "AltTabby" -ErrorAction SilentlyContinue
        if ($running) {
            Write-Host "  Stopping running AltTabby processes..."
            Stop-Process -Name "AltTabby" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }

        Write-Host "  Running compile.bat..."
        $compileExit = [SilentProcess]::RunWait(('cmd.exe /c "' + $compileBat + '" < nul'), $compileDir)

        Record-PhaseEnd "Compilation"
        if ($compileExit -eq 0 -and (Test-Path $outFile)) {
            Write-Host "PASS: compile.bat completed" -ForegroundColor Green
        } else {
            Write-Host "FAIL: compile.bat failed (exit $compileExit)" -ForegroundColor Red
            Write-Host "Aborting - compiled exe required for live tests" -ForegroundColor Red
            Show-TimingReport
            exit 1
        }
    } else {
        Record-PhaseEnd "Compilation"
        Write-Host "FAIL: compile.bat not found" -ForegroundColor Red
        Show-TimingReport
        exit 1
    }
} else {
    Record-PhaseStart "Compilation"
    Write-Host "`n--- Compilation Phase ---" -ForegroundColor Yellow
    # Continue with compilation (non-live mode)
    if (Test-Path $compiler) {
        # Check if recompilation is needed by comparing timestamps
        $needsCompile = $true
        $skipReason = ""

        if (-not $forceCompile -and (Test-Path $outFile)) {
            $exeTime = (Get-Item $outFile).LastWriteTime
            $newestSrc = Get-ChildItem -Path $srcRoot -Filter "*.ahk" -Recurse |
                         Sort-Object LastWriteTime -Descending |
                         Select-Object -First 1

            if ($newestSrc -and $exeTime -gt $newestSrc.LastWriteTime) {
                $needsCompile = $false
                $skipReason = "exe newer than source (newest: $($newestSrc.Name))"
            }
        }

        if ($forceCompile) {
            Write-Host "Recompiling (--force-compile specified)..."
        } elseif (-not $needsCompile) {
            Write-Host "SKIP: Compilation skipped - $skipReason" -ForegroundColor Cyan
            Write-Host "      Use --force-compile to override" -ForegroundColor DarkGray
        }

        if ($needsCompile) {
            if (-not $forceCompile) {
                Write-Host "Recompiling source to ensure tests use current code..."
            }

            # Kill any running AltTabby processes first
            $running = Get-Process -Name "AltTabby" -ErrorAction SilentlyContinue
            if ($running) {
                Write-Host "  Stopping running AltTabby processes..."
                Stop-Process -Name "AltTabby" -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
            }

            # Ensure release directory exists
            if (-not (Test-Path $releaseDir)) {
                New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
            }

            # Compile using SilentProcess to suppress cursor feedback
            $compileArgStr = "/in `"$srcFile`" /out `"$outFile`" /base `"$ahkBase`" /silent verbose"
            $compileExit = [SilentProcess]::RunWait('"' + $compiler + '" ' + $compileArgStr)

            if ($compileExit -eq 0 -and (Test-Path $outFile)) {
                Write-Host "PASS: Compiled AltTabby.exe successfully" -ForegroundColor Green
            } else {
                Write-Host "FAIL: Compilation failed (exit code: $compileExit)" -ForegroundColor Red
                # Continue with tests anyway - compiled exe tests will be skipped if exe doesn't exist
            }
        }
    } else {
        Write-Host "SKIP: Ahk2Exe.exe not found - compiled exe tests will use existing binary" -ForegroundColor Yellow
    }
    Record-PhaseEnd "Compilation"
}

# --- Test Execution ---
$mainExitCode = 0

if ($live) {
    # === All-Parallel Live Test Pipeline ===
    # Phase 0 (above): Syntax + GUI + compile.bat
    # Phase 1 (here): ALL suites launch simultaneously
    # Safe because: Features + Core use AHK stores, Execution uses AltTabby.exe
    # All use unique pipe names with timestamps — no collisions

    $coreLogFile = "$env:TEMP\alt_tabby_tests_core.log"
    $featuresLogFile = "$env:TEMP\alt_tabby_tests_features.log"
    $executionLogFile = "$env:TEMP\alt_tabby_tests_execution.log"
    $coreStderrFile = "$env:TEMP\ahk_core_stderr.log"
    $featuresStderrFile = "$env:TEMP\ahk_features_stderr.log"
    $executionStderrFile = "$env:TEMP\ahk_execution_stderr.log"
    $stderrFile = "$env:TEMP\ahk_stderr.log"

    # Clean parallel log files
    foreach ($f in @($coreLogFile, $featuresLogFile, $executionLogFile, $coreStderrFile, $featuresStderrFile, $executionStderrFile, $stderrFile)) {
        Remove-Item -Force -ErrorAction SilentlyContinue $f
    }

    $liveStart = Get-Date
    Record-PhaseStart "Live Tests"

    # --- All Suites (parallel) ---
    Write-Host "`n--- All Suites (parallel) ---" -ForegroundColor Yellow

    # All suites launched directly (no cmd.exe) — FORCEOFFEEDBACK applies to AHK itself
    Write-Host "  Starting Features tests (background)..." -ForegroundColor Cyan
    $featuresHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-features', $featuresStderrFile)

    Write-Host "  Starting Core tests (background)..." -ForegroundColor Cyan
    $coreHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-core', $coreStderrFile)

    Write-Host "  Starting Execution tests (background)..." -ForegroundColor Cyan
    $executionHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-execution', $executionStderrFile)

    # Launch Unit via StartCaptured (not RunWaitCaptured) so we have its handle for polling
    Write-Host "  Starting Unit tests..." -ForegroundColor Cyan
    $unitHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '"', $stderrFile)

    # --- Timing: poll all 4 handles to record actual completion times ---
    if ($timing) {
        $pollSw = [System.Diagnostics.Stopwatch]::StartNew()
        $suiteHandles = @{
            Unit      = $unitHandle
            Features  = $featuresHandle
            Core      = $coreHandle
            Execution = $executionHandle
        }
        $suiteDone = @{}
        while ($suiteDone.Count -lt $suiteHandles.Count) {
            foreach ($name in $suiteHandles.Keys) {
                if ($suiteDone.ContainsKey($name)) { continue }
                $code = [SilentProcess]::TryGetExitCode($suiteHandles[$name])
                if ($code -ne -259) {
                    $suiteDone[$name] = $pollSw.ElapsedMilliseconds
                }
            }
            if ($suiteDone.Count -lt $suiteHandles.Count) {
                Start-Sleep -Milliseconds 25
            }
        }
        $pollSw.Stop()
        Record-PhaseEnd "Live Tests"
        foreach ($name in $suiteDone.Keys) {
            Record-ItemTiming -Phase "Live Tests" -Item $name -DurationMs $suiteDone[$name]
        }
    }

    # Wait for Unit (blocking — instant if polling already detected completion)
    $unitExit = [SilentProcess]::WaitAndGetExitCode($unitHandle)

    $stderr = Get-Content $stderrFile -ErrorAction SilentlyContinue
    if ($stderr) {
        Write-Host "=== UNIT TEST ERRORS ===" -ForegroundColor Red
        Write-Host $stderr
    }

    Show-TestSummary -LogPath $logFile -Label "Unit"

    if ($unitExit -ne 0) {
        $mainExitCode = $unitExit
    }

    # --- Collect Results (wait for all background processes) ---

    Write-Host "`n--- Core Test Results ---" -ForegroundColor Yellow
    $coreExitCode = [SilentProcess]::WaitAndGetExitCode($coreHandle)

    $coreStderr = Get-Content $coreStderrFile -ErrorAction SilentlyContinue
    if ($coreStderr) {
        Write-Host "=== CORE TEST ERRORS ===" -ForegroundColor Red
        Write-Host $coreStderr
    }
    Show-TestSummary -LogPath $coreLogFile -Label "Core"

    if ($coreExitCode -ne 0) { $mainExitCode = $coreExitCode }

    Write-Host "`n--- Execution Test Results ---" -ForegroundColor Yellow
    $execExitCode = [SilentProcess]::WaitAndGetExitCode($executionHandle)

    $executionStderr = Get-Content $executionStderrFile -ErrorAction SilentlyContinue
    if ($executionStderr) {
        Write-Host "=== EXECUTION TEST ERRORS ===" -ForegroundColor Red
        Write-Host $executionStderr
    }
    Show-TestSummary -LogPath $executionLogFile -Label "Execution"

    if ($execExitCode -ne 0) { $mainExitCode = $execExitCode }

    Write-Host "`n--- Features Test Results ---" -ForegroundColor Yellow
    $featuresExitCode = [SilentProcess]::WaitAndGetExitCode($featuresHandle)

    $featuresStderr = Get-Content $featuresStderrFile -ErrorAction SilentlyContinue
    if ($featuresStderr) {
        Write-Host "=== FEATURES TEST ERRORS ===" -ForegroundColor Red
        Write-Host $featuresStderr
    }
    Show-TestSummary -LogPath $featuresLogFile -Label "Features"

    if ($featuresExitCode -ne 0) { $mainExitCode = $featuresExitCode }

    if (-not $timing) { Record-PhaseEnd "Live Tests" }
    $liveElapsed = ((Get-Date) - $liveStart).TotalSeconds
    Write-Host "`n  Live pipeline completed in $([math]::Round($liveElapsed, 1))s" -ForegroundColor Cyan
} else {
    # === Non-live mode: unit tests only ===
    Record-PhaseStart "Unit Tests"
    Write-Host "`n--- Unit Tests Phase ---" -ForegroundColor Yellow

    $stderrFile = "$env:TEMP\ahk_stderr.log"
    Remove-Item -Force -ErrorAction SilentlyContinue $stderrFile

    $mainExitCode = [SilentProcess]::RunWaitCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '"', $stderrFile)
    Record-PhaseEnd "Unit Tests"

    $stderr = Get-Content $stderrFile -ErrorAction SilentlyContinue
    if ($stderr) {
        Write-Host "=== ERRORS ===" -ForegroundColor Red
        Write-Host $stderr
    }

    Show-TestSummary -LogPath $logFile -Label "Unit"
}

# --- GUI Tests Phase (Collect Results) ---
Write-Host "`n--- GUI Tests Phase ---" -ForegroundColor Yellow

if ($guiHandle -ne [IntPtr]::Zero) {
    $guiExitCode = [SilentProcess]::WaitAndGetExitCode($guiHandle)
    Record-PhaseEnd "GUI Tests (background)"
    Show-TestSummary -LogPath $guiLogFile -Label "GUI"

    if ($guiExitCode -ne 0) {
        $mainExitCode = $guiExitCode
    }
} else {
    Write-Host "  SKIP: gui_tests.ahk not found" -ForegroundColor Yellow
}

Show-TimingReport
exit $mainExitCode
