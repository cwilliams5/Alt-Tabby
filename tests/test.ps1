# Alt-Tabby Test Runner
# Usage: .\tests\test.ps1 [--live] [--force-compile]

param(
    [switch]$live,
    [Alias("force-compile")]
    [switch]$forceCompile,
    [Parameter(ValueFromRemainingArguments=$true)]
    $remainingArgs
)

# HARDENING: Detect when called incorrectly via `powershell -Command`
# With -Command, switch params aren't parsed correctly and end up in $remainingArgs
# This MUST fail hard - warnings get ignored by LLM agents
if ($remainingArgs) {
    foreach ($arg in $remainingArgs) {
        if ($arg -match '^-{1,2}(live|force-?compile)$') {
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
}
"@

$ahk = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$script = "$PSScriptRoot\run_tests.ahk"
$logFile = "$env:TEMP\alt_tabby_tests.log"
$srcRoot = (Resolve-Path "$PSScriptRoot\..\src").Path

# Remove old logs
Remove-Item -Force -ErrorAction SilentlyContinue $logFile

Write-Host "=== Alt-Tabby Test Run $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Cyan
Write-Host "Log file: $logFile"

# --- Syntax Check Phase (Parallel) ---
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
$syntaxErrors = 0
foreach ($sp in $syntaxProcs) {
    if ($sp.Handle -eq [IntPtr]::Zero) {
        Write-Host "FAIL: $($sp.FileName) (failed to launch)" -ForegroundColor Red
        $syntaxErrors++
        continue
    }
    $exitCode = [SilentProcess]::WaitAndGetExitCode($sp.Handle)
    if ($exitCode -ne 0) {
        Write-Host "FAIL: $($sp.FileName)" -ForegroundColor Red
        $errContent = if (Test-Path $sp.ErrFile) { Get-Content $sp.ErrFile -Raw -ErrorAction SilentlyContinue } else { "" }
        if ($errContent) { Write-Host $errContent -ForegroundColor Red }
        $syntaxErrors++
    } else {
        Write-Host "PASS: $($sp.FileName)" -ForegroundColor Green
    }
}

if ($syntaxErrors -gt 0) {
    Write-Host "`n=== SYNTAX ERRORS FOUND: $syntaxErrors ===" -ForegroundColor Red
    Write-Host "Fix syntax errors before running tests." -ForegroundColor Red
    exit 1
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
    $guiHandle = [SilentProcess]::Start('"' + $ahk + '" /ErrorStdOut "' + $guiScript + '"')
}

if ($live) {
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

        if ($compileExit -eq 0 -and (Test-Path $outFile)) {
            Write-Host "PASS: compile.bat completed" -ForegroundColor Green
        } else {
            Write-Host "FAIL: compile.bat failed (exit $compileExit)" -ForegroundColor Red
            Write-Host "Aborting - compiled exe required for live tests" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "FAIL: compile.bat not found" -ForegroundColor Red
        exit 1
    }
} else {
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

    # --- All Suites (parallel) ---
    Write-Host "`n--- All Suites (parallel) ---" -ForegroundColor Yellow

    # All suites launched directly (no cmd.exe) — FORCEOFFEEDBACK applies to AHK itself
    Write-Host "  Starting Features tests (background)..." -ForegroundColor Cyan
    $featuresHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-features', $featuresStderrFile)

    Write-Host "  Starting Core tests (background)..." -ForegroundColor Cyan
    $coreHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-core', $coreStderrFile)

    Write-Host "  Starting Execution tests (background)..." -ForegroundColor Cyan
    $executionHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-execution', $executionStderrFile)

    Write-Host "  Running Unit tests (foreground)..." -ForegroundColor Cyan
    $unitExit = [SilentProcess]::RunWaitCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '"', $stderrFile)

    $stderr = Get-Content $stderrFile -ErrorAction SilentlyContinue
    if ($stderr) {
        Write-Host "=== UNIT TEST ERRORS ===" -ForegroundColor Red
        Write-Host $stderr
    }

    if (Test-Path $logFile) {
        Get-Content $logFile
    } else {
        Write-Host "Unit test log not found - tests may have failed to run" -ForegroundColor Red
    }

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
    if (Test-Path $coreLogFile) {
        Get-Content $coreLogFile
    } else {
        Write-Host "Core test log not found - tests may have failed to run" -ForegroundColor Red
    }

    if ($coreExitCode -ne 0) { $mainExitCode = $coreExitCode }

    Write-Host "`n--- Execution Test Results ---" -ForegroundColor Yellow
    $execExitCode = [SilentProcess]::WaitAndGetExitCode($executionHandle)

    $executionStderr = Get-Content $executionStderrFile -ErrorAction SilentlyContinue
    if ($executionStderr) {
        Write-Host "=== EXECUTION TEST ERRORS ===" -ForegroundColor Red
        Write-Host $executionStderr
    }
    if (Test-Path $executionLogFile) {
        Get-Content $executionLogFile
    } else {
        Write-Host "Execution test log not found - tests may have failed to run" -ForegroundColor Red
    }

    if ($execExitCode -ne 0) { $mainExitCode = $execExitCode }

    Write-Host "`n--- Features Test Results ---" -ForegroundColor Yellow
    $featuresExitCode = [SilentProcess]::WaitAndGetExitCode($featuresHandle)

    $featuresStderr = Get-Content $featuresStderrFile -ErrorAction SilentlyContinue
    if ($featuresStderr) {
        Write-Host "=== FEATURES TEST ERRORS ===" -ForegroundColor Red
        Write-Host $featuresStderr
    }
    if (Test-Path $featuresLogFile) {
        Get-Content $featuresLogFile
    } else {
        Write-Host "Features test log not found - tests may have failed to run" -ForegroundColor Red
    }

    if ($featuresExitCode -ne 0) { $mainExitCode = $featuresExitCode }

    $liveElapsed = ((Get-Date) - $liveStart).TotalSeconds
    Write-Host "`n  Live pipeline completed in $([math]::Round($liveElapsed, 1))s" -ForegroundColor Cyan
} else {
    # === Non-live mode: unit tests only ===
    Write-Host "`n--- Unit Tests Phase ---" -ForegroundColor Yellow

    $stderrFile = "$env:TEMP\ahk_stderr.log"
    Remove-Item -Force -ErrorAction SilentlyContinue $stderrFile

    $mainExitCode = [SilentProcess]::RunWaitCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '"', $stderrFile)

    $stderr = Get-Content $stderrFile -ErrorAction SilentlyContinue
    if ($stderr) {
        Write-Host "=== ERRORS ===" -ForegroundColor Red
        Write-Host $stderr
    }

    if (Test-Path $logFile) {
        Get-Content $logFile
    } else {
        Write-Host "Test log not found - tests may have failed to run" -ForegroundColor Red
    }
}

# --- GUI Tests Phase (Collect Results) ---
Write-Host "`n--- GUI Tests Phase ---" -ForegroundColor Yellow

if ($guiHandle -ne [IntPtr]::Zero) {
    Write-Host "Waiting for GUI tests to complete..."
    $guiExitCode = [SilentProcess]::WaitAndGetExitCode($guiHandle)

    # Show results
    if (Test-Path $guiLogFile) {
        Get-Content $guiLogFile
    } else {
        Write-Host "GUI test log not found - tests may have failed to run" -ForegroundColor Red
    }

    if ($guiExitCode -ne 0) {
        $mainExitCode = $guiExitCode
    }
} else {
    Write-Host "SKIP: gui_tests.ahk not found" -ForegroundColor Yellow
}

exit $mainExitCode
