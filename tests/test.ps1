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

# --- Shared paths ---
$compiler = "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe"
$ahkBase = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$srcFile = "$srcRoot\alt_tabby.ahk"
$releaseDir = (Resolve-Path "$PSScriptRoot\..").Path + "\release"
$outFile = "$releaseDir\AltTabby.exe"
$compileBat = (Resolve-Path "$PSScriptRoot\..").Path + "\compile.bat"
$compileDir = (Resolve-Path "$PSScriptRoot\..").Path
$staticAnalysisScript = "$PSScriptRoot\static_analysis.ps1"
$guiScript = "$PSScriptRoot\gui_tests.ahk"
$guiLogFile = "$env:TEMP\gui_tests.log"
$guiHandle = [IntPtr]::Zero
$guiTimingRecorded = $false
$compileHandle = [IntPtr]::Zero

Remove-Item -Force -ErrorAction SilentlyContinue $guiLogFile

# --- Live mode: Kill AltTabby + start compilation early (background) ---
# Compilation overlaps with pre-gate checks to save ~3s on the critical path.
# Safe because: Ahk2Exe reads source files (no write conflicts), runs silently,
# and is killed if pre-gates fail.
if ($live) {
    # Kill running AltTabby processes first (must happen before compile touches exe)
    $running = Get-Process -Name "AltTabby" -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host "Stopping running AltTabby processes..." -ForegroundColor Yellow
        Stop-Process -Name "AltTabby" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }

    if (Test-Path $compileBat) {
        Record-PhaseStart "Compilation"
        Write-Host "Starting compilation in background..." -ForegroundColor Cyan
        $compileOutFile = "$env:TEMP\compile_captured.log"
        Remove-Item -Force -ErrorAction SilentlyContinue $compileOutFile
        $compileHandle = [SilentProcess]::StartCaptured(('cmd.exe /c "' + $compileBat + '" < nul'), $compileOutFile, $compileDir)
    }
}

# --- Pre-Gate Phase: Syntax Check + Static Analysis (Parallel) ---
# Both are independent text-scanning checks. Neither depends on the other.
# Both must pass before any AHK test process launches.
Record-PhaseStart "Pre-Gate (Syntax + Static Analysis)"
Write-Host "`n--- Pre-Gate: Syntax Check + Static Analysis (Parallel) ---" -ForegroundColor Yellow

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

# Launch static analysis in background (captured to temp file)
$saOutFile = "$env:TEMP\sa_captured_output.log"
$saHandle = [IntPtr]::Zero
$saExit = 0
Remove-Item -Force -ErrorAction SilentlyContinue $saOutFile

if (Test-Path $staticAnalysisScript) {
    $saTimingArg = if ($timing) { " -Timing" } else { "" }
    $saCmdLine = 'powershell.exe -NoProfile -File "' + $staticAnalysisScript + '" -SourceDir "' + $srcRoot + '"' + $saTimingArg
    $saHandle = [SilentProcess]::StartCaptured($saCmdLine, $saOutFile)
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
if ($syntaxFailed -gt 0) {
    Write-Host "  Syntax: $syntaxPassed/$syntaxTotal passed, $syntaxFailed failed [FAIL]" -ForegroundColor Red
} else {
    Write-Host "  Syntax: $syntaxTotal/$syntaxTotal passed [PASS]" -ForegroundColor Green
}

# Wait for static analysis to complete and show results
if ($saHandle -ne [IntPtr]::Zero) {
    $saExit = [SilentProcess]::WaitAndGetExitCode($saHandle)

    # Replay captured SA output
    Write-Host ""
    if (Test-Path $saOutFile) {
        $saOutput = Get-Content $saOutFile -Raw -ErrorAction SilentlyContinue
        if ($saOutput) { Write-Host $saOutput.TrimEnd() }
        Remove-Item -Force -ErrorAction SilentlyContinue $saOutFile
    }

    # Read per-check timing data if available
    $saTimingFile = "$env:TEMP\sa_timing.json"
    if ($timing -and (Test-Path $saTimingFile)) {
        $saTimingData = Get-Content $saTimingFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($saTimingData) {
            foreach ($entry in $saTimingData) {
                Record-ItemTiming -Phase "Pre-Gate (Syntax + Static Analysis)" -Item $entry.Name -DurationMs $entry.DurationMs
            }
        }
        Remove-Item -Force -ErrorAction SilentlyContinue $saTimingFile
    }
} elseif (-not (Test-Path $staticAnalysisScript)) {
    Write-Host "  SKIP: static_analysis.ps1 not found" -ForegroundColor Yellow
}

Record-PhaseEnd "Pre-Gate (Syntax + Static Analysis)"

# Check for pre-gate failures — kill background compilation if needed
$preGateFailed = $false
if ($syntaxFailed -gt 0 -or $saExit -ne 0) {
    $preGateFailed = $true

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
    }

    # Kill background compilation if it was started
    if ($compileHandle -ne [IntPtr]::Zero) {
        # TryGetExitCode returns -259 if still running; if so, terminate it
        $compileCode = [SilentProcess]::TryGetExitCode($compileHandle)
        if ($compileCode -eq -259) {
            # Process still running — terminate via handle
            Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class ProcHelper { [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr h, uint code); [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h); }'
            [ProcHelper]::TerminateProcess($compileHandle, 1) | Out-Null
            [ProcHelper]::CloseHandle($compileHandle) | Out-Null
        } else {
            # Already exited — just close the handle
            Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class ProcHelper2 { [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h); }' -ErrorAction SilentlyContinue
            try { [ProcHelper2]::CloseHandle($compileHandle) | Out-Null } catch {}
        }
        Record-PhaseEnd "Compilation"
    }

    Show-TimingReport
    exit 1
}

# --- Start GUI Tests (Background) ---
# GUI tests depend on pre-gates passing (they execute AHK code) but not on compilation.
if (Test-Path $guiScript) {
    Write-Host "Starting GUI tests in background..." -ForegroundColor Cyan
    Record-PhaseStart "GUI Tests (background)"
    $guiHandle = [SilentProcess]::Start('"' + $ahk + '" /ErrorStdOut "' + $guiScript + '"')
}

# --- Compilation Phase ---
if ($live) {
    Write-Host "`n--- Compilation Phase (compile.bat) ---" -ForegroundColor Yellow

    if ($compileHandle -ne [IntPtr]::Zero) {
        # Compilation was started in background — wait for it
        Write-Host "  Waiting for background compilation..."
        $compileExit = [SilentProcess]::WaitAndGetExitCode($compileHandle)
        Record-PhaseEnd "Compilation"
        if ($compileExit -eq 0 -and (Test-Path $outFile)) {
            Write-Host "PASS: compile.bat completed" -ForegroundColor Green
        } else {
            Write-Host "FAIL: compile.bat failed (exit $compileExit)" -ForegroundColor Red
            Write-Host "Aborting - compiled exe required for live tests" -ForegroundColor Red
            Show-TimingReport
            exit 1
        }
    } elseif (Test-Path $compileBat) {
        # compile.bat not found at early launch — try now
        Record-PhaseStart "Compilation"
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

# --- Check if GUI tests already finished (accurate timing) ---
# GUI tests take ~1s but WaitAndGetExitCode below is called much later,
# so record the phase end now if the process has already exited.
if ($guiHandle -ne [IntPtr]::Zero) {
    $guiCode = [SilentProcess]::TryGetExitCode($guiHandle)
    if ($guiCode -ne -259) {
        Record-PhaseEnd "GUI Tests (background)"
        $guiTimingRecorded = $true
    }
}

# --- Unit Suite Metadata (data-driven, avoids 5x copy-paste) ---
$unitSuites = @(
    @{ Name = "UnitCore";     Flag = "--unit-core";     Label = "Unit/Core";     LogSuffix = "unit_core" },
    @{ Name = "UnitStorage";  Flag = "--unit-storage";  Label = "Unit/Storage";  LogSuffix = "unit_storage" },
    @{ Name = "UnitSetup";    Flag = "--unit-setup";    Label = "Unit/Setup";    LogSuffix = "unit_setup" },
    @{ Name = "UnitCleanup";  Flag = "--unit-cleanup";  Label = "Unit/Cleanup";  LogSuffix = "unit_cleanup" },
    @{ Name = "UnitAdvanced"; Flag = "--unit-advanced";  Label = "Unit/Advanced"; LogSuffix = "unit_advanced" }
)

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

    # Build list of all log files to clean (live + unit suites)
    $cleanFiles = @($coreLogFile, $featuresLogFile, $executionLogFile, $coreStderrFile, $featuresStderrFile, $executionStderrFile)
    foreach ($us in $unitSuites) {
        $cleanFiles += "$env:TEMP\alt_tabby_tests_$($us.LogSuffix).log"
        $cleanFiles += "$env:TEMP\ahk_$($us.LogSuffix)_stderr.log"
    }
    foreach ($f in $cleanFiles) {
        Remove-Item -Force -ErrorAction SilentlyContinue $f
    }

    $liveStart = Get-Date

    # --- All 8 suites (parallel: 5 unit + 3 live) ---
    Write-Host "`n--- Test Execution (8 suites, parallel) ---" -ForegroundColor Yellow
    Record-PhaseStart "Test Execution"

    foreach ($us in $unitSuites) {
        $us.StderrFile = "$env:TEMP\ahk_$($us.LogSuffix)_stderr.log"
        $us.LogFile = "$env:TEMP\alt_tabby_tests_$($us.LogSuffix).log"
        Write-Host "  Starting $($us.Label) tests (background)..." -ForegroundColor Cyan
        $us.Handle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" ' + $us.Flag, $us.StderrFile)
    }

    Write-Host "  Starting Live/Features tests (background)..." -ForegroundColor Cyan
    $featuresHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-features', $featuresStderrFile)

    Write-Host "  Starting Live/Core tests (background)..." -ForegroundColor Cyan
    $coreHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-core', $coreStderrFile)

    Write-Host "  Starting Live/Execution tests (background)..." -ForegroundColor Cyan
    $executionHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-execution', $executionStderrFile)

    # --- Timing: poll all 8 handles to record actual completion times ---
    if ($timing) {
        $pollSw = [System.Diagnostics.Stopwatch]::StartNew()
        $suiteHandles = @{
            "Live/Features"  = $featuresHandle
            "Live/Core"      = $coreHandle
            "Live/Execution" = $executionHandle
        }
        foreach ($us in $unitSuites) {
            $suiteHandles[$us.Label] = $us.Handle
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
        Record-PhaseEnd "Test Execution"

        foreach ($label in $suiteDone.Keys) {
            Record-ItemTiming -Phase "Test Execution" -Item $label -DurationMs $suiteDone[$label]
        }
    }

    # --- Collect Unit Results ---
    Write-Host "`n--- Unit Test Results ---" -ForegroundColor Yellow
    foreach ($us in $unitSuites) {
        $usExit = [SilentProcess]::WaitAndGetExitCode($us.Handle)
        $usStderr = Get-Content $us.StderrFile -ErrorAction SilentlyContinue
        if ($usStderr) {
            Write-Host "=== $($us.Label.ToUpper()) ERRORS ===" -ForegroundColor Red
            Write-Host $usStderr
        }
        Show-TestSummary -LogPath $us.LogFile -Label $us.Label
        if ($usExit -ne 0) { $mainExitCode = $usExit }
    }

    # --- Collect Live Results ---

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

    if (-not $timing) {
        Record-PhaseEnd "Test Execution"
    }
    $liveElapsed = ((Get-Date) - $liveStart).TotalSeconds
    Write-Host "`n  Live pipeline completed in $([math]::Round($liveElapsed, 1))s" -ForegroundColor Cyan
} else {
    # === Non-live mode: 5-way parallel unit tests ===
    Record-PhaseStart "Unit Tests"
    Write-Host "`n--- Unit Tests Phase (parallel) ---" -ForegroundColor Yellow

    # Clean log files
    foreach ($us in $unitSuites) {
        $us.StderrFile = "$env:TEMP\ahk_$($us.LogSuffix)_stderr.log"
        $us.LogFile = "$env:TEMP\alt_tabby_tests_$($us.LogSuffix).log"
        Remove-Item -Force -ErrorAction SilentlyContinue $us.StderrFile
        Remove-Item -Force -ErrorAction SilentlyContinue $us.LogFile
    }

    # Launch all 5 unit suites in parallel
    foreach ($us in $unitSuites) {
        Write-Host "  Starting $($us.Label) tests (background)..." -ForegroundColor Cyan
        $us.Handle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" ' + $us.Flag, $us.StderrFile)
    }

    # --- Timing: poll all 5 handles ---
    if ($timing) {
        $pollSw = [System.Diagnostics.Stopwatch]::StartNew()
        $suiteHandles = @{}
        foreach ($us in $unitSuites) {
            $suiteHandles[$us.Name] = $us.Handle
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
        Record-PhaseEnd "Unit Tests"
        foreach ($us in $unitSuites) {
            if ($suiteDone.ContainsKey($us.Name)) {
                Record-ItemTiming -Phase "Unit Tests" -Item $us.Label -DurationMs $suiteDone[$us.Name]
            }
        }
    }

    # Collect results
    Write-Host ""
    foreach ($us in $unitSuites) {
        $usExit = [SilentProcess]::WaitAndGetExitCode($us.Handle)
        $usStderr = Get-Content $us.StderrFile -ErrorAction SilentlyContinue
        if ($usStderr) {
            Write-Host "=== $($us.Label.ToUpper()) ERRORS ===" -ForegroundColor Red
            Write-Host $usStderr
        }
        Show-TestSummary -LogPath $us.LogFile -Label $us.Label
        if ($usExit -ne 0) { $mainExitCode = $usExit }
    }

    if (-not $timing) { Record-PhaseEnd "Unit Tests" }
}

# --- GUI Tests Phase (Collect Results) ---
Write-Host "`n--- GUI Tests Phase ---" -ForegroundColor Yellow

if ($guiHandle -ne [IntPtr]::Zero) {
    $guiExitCode = [SilentProcess]::WaitAndGetExitCode($guiHandle)
    if (-not $guiTimingRecorded) {
        Record-PhaseEnd "GUI Tests (background)"
    }
    Show-TestSummary -LogPath $guiLogFile -Label "GUI"

    if ($guiExitCode -ne 0) {
        $mainExitCode = $guiExitCode
    }
} else {
    Write-Host "  SKIP: gui_tests.ahk not found" -ForegroundColor Yellow
}

Show-TimingReport
exit $mainExitCode
