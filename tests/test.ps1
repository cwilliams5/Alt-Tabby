# Alt-Tabby Test Runner
# Usage: .\tests\test.ps1 [--live] [--force-compile] [--timing]
# --timing implies --live (bottleneck analysis requires the full pipeline)

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

# --timing implies --live (bottleneck analysis requires the full pipeline)
if ($timing) { $live = $true }

# Ensure UTF-8 output for box-drawing characters in timing report
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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
    param([string]$Phase, [string]$Item, [double]$DurationMs, [double]$OffsetMs = -1)
    if (-not $script:timing) { return }
    [void]$script:timingEvents.Add(@{
        Type       = "item"
        Phase      = $Phase
        Item       = $Item
        DurationMs = $DurationMs
        OffsetMs   = $OffsetMs
    })
}

function Show-TimingReport {
    if (-not $script:timing) { return }

    # --- Collect phase data ---
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
                    EndMs      = $ev.TickMs
                })
            }
        }
    }

    # --- Collect items per phase ---
    $phaseItems = @{}
    foreach ($ev in $script:timingEvents) {
        if ($ev.Type -eq "item") {
            if (-not $phaseItems.ContainsKey($ev.Phase)) { $phaseItems[$ev.Phase] = [System.Collections.ArrayList]::new() }
            [void]$phaseItems[$ev.Phase].Add(@{ Item = $ev.Item; DurationMs = $ev.DurationMs; OffsetMs = $ev.OffsetMs })
        }
    }

    $totalMs = $script:masterSw.ElapsedMilliseconds

    # --- Identify phases ---
    $compPhase = $phases | Where-Object { $_.Name -eq "Compilation" } | Select-Object -First 1
    $preGatePhase = $phases | Where-Object { $_.Name -eq "Pre-Gate" } | Select-Object -First 1
    $testsPhase = $phases | Where-Object { $_.Name -eq "Tests" } | Select-Object -First 1

    if (-not $preGatePhase -or -not $testsPhase) {
        # Fallback: not enough data for hierarchical report
        Write-Host "`n=== TIMING REPORT ===" -ForegroundColor Cyan
        Write-Host "  Insufficient timing data for report" -ForegroundColor Yellow
        return
    }

    # --- Phase 1: Pre-Gate + Compilation ---
    # Phase 1 offset = earliest start, duration = latest end - earliest start
    $p1OffsetMs = $preGatePhase.OffsetMs
    $p1EndMs = $preGatePhase.EndMs
    if ($compPhase) {
        $p1OffsetMs = [Math]::Min($p1OffsetMs, $compPhase.OffsetMs)
        $p1EndMs = [Math]::Max($p1EndMs, $compPhase.EndMs)
    }
    $p1DurationMs = $p1EndMs - $p1OffsetMs

    # --- Phase 2: Tests ---
    $p2OffsetMs = $testsPhase.OffsetMs
    $p2DurationMs = $testsPhase.DurationMs

    # --- Gate arrow logic ---
    # Two gates: Pre-Gate and Compilation. The one that finishes first gets the inner
    # arrow (its target launches first = higher in the list). The later one gets outer.
    # If no compilation or no stagger, no arrows.
    $hasGateArrows = $false
    $outerGateName = ""
    $innerGateName = ""
    $outerTargetOffsetMs = 0
    $innerTargetOffsetMs = 0

    if ($compPhase -and $phaseItems.ContainsKey("Tests")) {
        $testItems = $phaseItems["Tests"]
        # Find distinct offset values among test items
        $offsets = @($testItems | Where-Object { $_.OffsetMs -ge 0 } | ForEach-Object { $_.OffsetMs } | Sort-Object -Unique)
        if ($offsets.Count -ge 2) {
            $hasGateArrows = $true
            $earlyOffsetMs = $offsets[0]
            $lateOffsetMs = $offsets[1]

            # Pre-Gate finishes first → inner arrow (targets early wave)
            # Compilation finishes later → outer arrow (targets late wave)
            if ($preGatePhase.EndMs -le $compPhase.EndMs) {
                $innerGateName = "Pre-Gate"
                $innerTargetOffsetMs = $earlyOffsetMs
                $outerGateName = "Compilation"
                $outerTargetOffsetMs = $lateOffsetMs
            } else {
                $innerGateName = "Compilation"
                $innerTargetOffsetMs = $earlyOffsetMs
                $outerGateName = "Pre-Gate"
                $outerTargetOffsetMs = $lateOffsetMs
            }
        }
    }

    # --- Determine bottleneck phase ---
    $bottleneckPhase = if ($p1DurationMs -ge $p2DurationMs) { 1 } else { 2 }

    # --- Box-drawing characters (PS 5.1 compatible) ---
    $CH_CORNER_TL = [char]0x250C  # ┌
    $CH_CORNER_BL = [char]0x2514  # └
    $CH_HLINE     = [char]0x2500  # ─
    $CH_VLINE     = [char]0x2502  # │
    $CH_ARROW_R   = [char]0x25B8  # ▸
    $CH_ARROW_L   = [char]0x25C4  # ◄
    $CH_DHLINE    = [char]0x2550  # ═

    $MRK_BOTTLENECK = " ${CH_ARROW_L}${CH_DHLINE}${CH_DHLINE} bottleneck"
    $MRK_SLOWEST    = " ${CH_ARROW_L}${CH_HLINE}${CH_HLINE} slowest"

    # --- Build output lines ---
    # Each line: @{ Prefix = "  "; Text = "name"; Offset = "+1.2s"; Duration = "3.4s"; Marker = "" }
    $lines = [System.Collections.ArrayList]::new()
    $colW = 50  # name column width (includes prefix)

    # Phase 1 header
    $p1Name = if ($compPhase) { "Phase 1: Pre-Gate + Compilation" } else { "Phase 1: Pre-Gate" }
    $p1Marker = if ($bottleneckPhase -eq 1) { $MRK_BOTTLENECK } else { "" }
    [void]$lines.Add(@{ Prefix = "   "; Name = $p1Name; OffsetMs = $p1OffsetMs; DurMs = $p1DurationMs; Marker = $p1Marker; IsHeader = $true })

    # Phase 1 items: Compilation and Pre-Gate (with sub-items)
    # Determine slowest in Phase 1 (Compilation vs Pre-Gate duration)
    $p1Items = [System.Collections.ArrayList]::new()
    if ($compPhase) { [void]$p1Items.Add(@{ Name = "Compilation"; DurMs = $compPhase.DurationMs }) }
    [void]$p1Items.Add(@{ Name = "Pre-Gate"; DurMs = $preGatePhase.DurationMs })
    $p1SlowestMs = ($p1Items | Sort-Object { $_.DurMs } -Descending | Select-Object -First 1).DurMs

    # Render Compilation + sub-items (from compile.ps1 --test-mode output)
    if ($compPhase) {
        $compMarker = if ($compPhase.DurationMs -eq $p1SlowestMs -and $p1Items.Count -gt 1) { $MRK_SLOWEST } else { "" }
        $compGateRole = if ($hasGateArrows -and $outerGateName -eq "Compilation") { "outer_start" } elseif ($hasGateArrows) { "inner_start" } else { "" }
        [void]$lines.Add(@{ Prefix = "     "; Name = "Compilation"; OffsetMs = -1; DurMs = $compPhase.DurationMs; Marker = $compMarker; GateRole = $compGateRole })

        # Compilation sub-items (step timings from compile.ps1 --test-mode)
        if ($phaseItems.ContainsKey("Compilation")) {
            $compSubItems = $phaseItems["Compilation"] | Sort-Object { $_.DurationMs } -Descending
            $compSubSlowestMs = $compSubItems[0].DurationMs
            foreach ($item in $compSubItems) {
                # Skip "slowest" marker when all items tied at 0ms (everything cached)
                $itemMarker = if ($item.DurationMs -eq $compSubSlowestMs -and $compSubSlowestMs -gt 0 -and @($compSubItems).Count -gt 1) { $MRK_SLOWEST } else { "" }
                [void]$lines.Add(@{ Prefix = "       "; Name = $item.Item; OffsetMs = -1; DurMs = $item.DurationMs; Marker = $itemMarker; GateRole = "" })
            }
        }
    }

    # Render Pre-Gate + sub-items
    $pgMarker = if ($preGatePhase.DurationMs -eq $p1SlowestMs -and $p1Items.Count -gt 1) { $MRK_SLOWEST } else { "" }
    $pgGateRole = if ($hasGateArrows -and $outerGateName -eq "Pre-Gate") { "outer_start" } elseif ($hasGateArrows) { "inner_start" } else { "" }
    [void]$lines.Add(@{ Prefix = "     "; Name = "Pre-Gate"; OffsetMs = -1; DurMs = $preGatePhase.DurationMs; Marker = $pgMarker; GateRole = $pgGateRole })

    # Pre-Gate sub-items
    if ($phaseItems.ContainsKey("Pre-Gate")) {
        $pgItems = $phaseItems["Pre-Gate"] | Sort-Object { $_.DurationMs } -Descending
        $pgSlowestMs = $pgItems[0].DurationMs
        $pgBodyRole = if ($pgGateRole -eq "outer_start") { "outer_body" } elseif ($pgGateRole -eq "inner_start") { "inner_body" } else { "" }
        foreach ($item in $pgItems) {
            $itemMarker = if ($item.DurationMs -eq $pgSlowestMs -and @($pgItems).Count -gt 1) { $MRK_SLOWEST } else { "" }
            [void]$lines.Add(@{ Prefix = "       "; Name = $item.Item; OffsetMs = -1; DurMs = $item.DurationMs; Marker = $itemMarker; GateRole = $pgBodyRole })
        }
    }

    # Phase 2 header
    $p2Marker = if ($bottleneckPhase -eq 2) { $MRK_BOTTLENECK } else { "" }
    [void]$lines.Add(@{ Prefix = "   "; Name = "Phase 2: Tests"; OffsetMs = $p2OffsetMs; DurMs = $p2DurationMs; Marker = $p2Marker; IsHeader = $true })

    # Phase 2 items sorted by duration descending, but early-offset items first within their wave
    if ($phaseItems.ContainsKey("Tests")) {
        $testItems = $phaseItems["Tests"] | Sort-Object { $_.DurationMs } -Descending
        $testSlowestMs = ($testItems | Select-Object -First 1).DurationMs

        # Separate into waves by offset, render early wave first
        $earlyWave = @($testItems | Where-Object { $hasGateArrows -and $_.OffsetMs -ge 0 -and $_.OffsetMs -eq $innerTargetOffsetMs })
        $lateWave = @($testItems | Where-Object { -not $hasGateArrows -or $_.OffsetMs -lt 0 -or $_.OffsetMs -ne $innerTargetOffsetMs })

        $allWaves = @()
        if ($earlyWave.Count -gt 0) { $allWaves += $earlyWave }
        if ($lateWave.Count -gt 0) { $allWaves += $lateWave }

        $prevOffsetMs = -2  # sentinel
        foreach ($item in $allWaves) {
            $itemMarker = if ($item.DurationMs -eq $testSlowestMs -and @($testItems).Count -gt 1) { $MRK_SLOWEST } else { "" }
            $showOffset = if ($item.OffsetMs -ge 0 -and $item.OffsetMs -ne $prevOffsetMs) { $item.OffsetMs } else { -1 }
            if ($item.OffsetMs -ge 0) { $prevOffsetMs = $item.OffsetMs }

            # Determine gate role for this item
            $role = ""
            if ($hasGateArrows -and $item.OffsetMs -ge 0) {
                if ($item.OffsetMs -eq $innerTargetOffsetMs -and $earlyWave.Count -gt 0 -and $item -eq $earlyWave[0]) {
                    $role = "inner_target"
                } elseif ($item.OffsetMs -eq $outerTargetOffsetMs -and $lateWave.Count -gt 0 -and $item -eq $lateWave[0]) {
                    $role = "outer_target"
                }
            }

            [void]$lines.Add(@{ Prefix = "       "; Name = $item.Item; OffsetMs = $showOffset; DurMs = $item.DurationMs; Marker = $itemMarker; GateRole = $role })
        }
    }

    # --- Render with gate arrows ---
    # Build the gate arrow prefix (4-char left margin) for each line
    # Track vertical positions of gate starts and targets
    $outerStartIdx = -1; $outerTargetIdx = -1
    $innerStartIdx = -1; $innerTargetIdx = -1

    if ($hasGateArrows) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $role = $lines[$i].GateRole
            if ($role -eq "outer_start") { $outerStartIdx = $i }
            if ($role -eq "inner_start") { $innerStartIdx = $i }
            if ($role -eq "inner_target") { $innerTargetIdx = $i }
            if ($role -eq "outer_target") { $outerTargetIdx = $i }
        }
    }

    Write-Host ""
    Write-Host "=== TIMING REPORT ===" -ForegroundColor Cyan
    $hdr = ("{0,-50}{1} {2}" -f "", "Offset".PadLeft(8), "Duration".PadLeft(10))
    Write-Host $hdr -ForegroundColor Cyan
    Write-Host ("-" * 70) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]

        # Build 5-char gate arrow prefix
        $g = "     "
        if ($hasGateArrows) {
            $c0 = " "; $c1 = " "; $c2 = " "; $c3 = " "; $c4 = " "

            # Outer arrow (column 0-1): ┌─ at start, │ in between, └──▸ at target
            if ($i -eq $outerStartIdx) { $c0 = $CH_CORNER_TL; $c1 = $CH_HLINE }
            elseif ($i -eq $outerTargetIdx) { $c0 = $CH_CORNER_BL; $c1 = $CH_HLINE; $c2 = $CH_HLINE; $c3 = $CH_ARROW_R }
            elseif ($i -gt $outerStartIdx -and $i -lt $outerTargetIdx) { $c0 = $CH_VLINE }

            # Inner arrow (column 1-2): ┌─ at start, │ in between, └▸ at target
            # Only draw inner if not overridden by outer on same position
            if ($i -eq $innerStartIdx) {
                $c1 = $CH_CORNER_TL; $c2 = $CH_HLINE
            } elseif ($i -eq $innerTargetIdx) {
                $c1 = $CH_CORNER_BL; $c2 = $CH_ARROW_R
            } elseif ($i -gt $innerStartIdx -and $i -lt $innerTargetIdx) {
                if ($c1 -eq " ") { $c1 = $CH_VLINE }
            }

            $g = "${c0}${c1}${c2}${c3}${c4}"
        }

        # Build the content
        $name = $ln.Name
        $prefix = $ln.Prefix
        $fullName = "${prefix}${name}"

        $offsetStr = ""
        if ($ln.OffsetMs -ge 0) { $offsetStr = "+{0:F1}s" -f ($ln.OffsetMs / 1000) }
        $durStr = "{0:F1}s" -f ($ln.DurMs / 1000)
        $marker = if ($ln.Marker) { $ln.Marker } else { "" }

        $nameCol = "${g}${fullName}"
        $padLen = 50 - $nameCol.Length
        if ($padLen -lt 1) { $padLen = 1 }
        $pad = " " * $padLen

        $offsetPad = $offsetStr.PadLeft(8)
        $durPad = $durStr.PadLeft(10)
        $text = "${nameCol}${pad}${offsetPad} ${durPad}${marker}"

        if ($ln.IsHeader) {
            Write-Host $text -ForegroundColor Cyan
        } else {
            Write-Host $text
        }
    }

    Write-Host ("-" * 70) -ForegroundColor DarkGray
    $totalStr = "{0:F1}s" -f ($totalMs / 1000)
    $totalLine = ("{0,-50}{1} {2}" -f "Total wall-clock", "".PadLeft(8), $totalStr.PadLeft(10))
    Write-Host $totalLine -ForegroundColor Cyan
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
$compilePs1 = (Resolve-Path "$PSScriptRoot\..").Path + "\compile.ps1"
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

    if (Test-Path $compilePs1) {
        Record-PhaseStart "Compilation"
        Write-Host "Starting compilation in background..." -ForegroundColor Cyan
        $compileOutFile = "$env:TEMP\compile_captured.log"
        Remove-Item -Force -ErrorAction SilentlyContinue $compileOutFile
        $compileFlags = "--test-mode"
        if ($timing) { $compileFlags += " --timing" }
        if ($forceCompile) { $compileFlags += " --force" }
        $compileHandle = [SilentProcess]::StartCaptured(('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $compilePs1 + '" ' + $compileFlags), $compileOutFile, $compileDir)
    }
}

# --- Pre-Gate Phase: Syntax Check + Static Analysis (Parallel) ---
# Both are independent text-scanning checks. Neither depends on the other.
# Both must pass before any AHK test process launches.
Record-PhaseStart "Pre-Gate"
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
                Record-ItemTiming -Phase "Pre-Gate" -Item $entry.Name -DurationMs $entry.DurationMs
            }
        }
        Remove-Item -Force -ErrorAction SilentlyContinue $saTimingFile
    }
} elseif (-not (Test-Path $staticAnalysisScript)) {
    Write-Host "  SKIP: static_analysis.ps1 not found" -ForegroundColor Yellow
}

Record-PhaseEnd "Pre-Gate"

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

# --- Unit Suite Metadata (data-driven, avoids 5x copy-paste) ---
$unitSuites = @(
    @{ Name = "UnitCore";     Flag = "--unit-core";     Label = "Unit/Core";     LogSuffix = "unit_core" },
    @{ Name = "UnitStorage";  Flag = "--unit-storage";  Label = "Unit/Storage";  LogSuffix = "unit_storage" },
    @{ Name = "UnitSetup";    Flag = "--unit-setup";    Label = "Unit/Setup";    LogSuffix = "unit_setup" },
    @{ Name = "UnitCleanup";  Flag = "--unit-cleanup";  Label = "Unit/Cleanup";  LogSuffix = "unit_cleanup" },
    @{ Name = "UnitAdvanced"; Flag = "--unit-advanced";  Label = "Unit/Advanced"; LogSuffix = "unit_advanced" }
)

# --- Start GUI Tests + Unit Tests (Background) ---
# GUI and unit tests depend on pre-gates passing (they execute AHK source directly)
# but NOT on compilation. Live tests launch later after compilation completes.
$guiStartTickMs = $masterSw.ElapsedMilliseconds
if (Test-Path $guiScript) {
    Write-Host "Starting GUI tests in background..." -ForegroundColor Cyan
    $guiHandle = [SilentProcess]::Start('"' + $ahk + '" /ErrorStdOut "' + $guiScript + '"')
}

# Launch unit suites immediately (they don't need compilation)
if ($live) {
    foreach ($us in $unitSuites) {
        $us.StderrFile = "$env:TEMP\ahk_$($us.LogSuffix)_stderr.log"
        $us.LogFile = "$env:TEMP\alt_tabby_tests_$($us.LogSuffix).log"
        Remove-Item -Force -ErrorAction SilentlyContinue $us.StderrFile
        Remove-Item -Force -ErrorAction SilentlyContinue $us.LogFile
        Write-Host "  Starting $($us.Label) tests (background)..." -ForegroundColor Cyan
        $us.Handle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" ' + $us.Flag, $us.StderrFile)
    }
}

# --- Compilation Phase ---
if ($live) {
    Write-Host "`n--- Compilation Phase (compile.ps1) ---" -ForegroundColor Yellow

    if ($compileHandle -ne [IntPtr]::Zero) {
        # Compilation was started in background — wait for it
        Write-Host "  Waiting for background compilation..."
        $compileExit = [SilentProcess]::WaitAndGetExitCode($compileHandle)
        Record-PhaseEnd "Compilation"
        # Parse compile.ps1 step timings from captured output
        if ($timing -and (Test-Path $compileOutFile)) {
            $compileTotalMs = 0
            foreach ($line in (Get-Content $compileOutFile -ErrorAction SilentlyContinue)) {
                if ($line -match '^TIMING:(.+):(\d+)$') {
                    $stepMs = [double]$Matches[2]
                    Record-ItemTiming -Phase "Compilation" -Item $Matches[1] -DurationMs $stepMs
                    $compileTotalMs += $stepMs
                }
            }
            # Fix phase duration: background compilation likely finished during pre-gate,
            # but WaitAndGetExitCode wasn't called until after. Use the actual step durations
            # (sequential sum) to correct the phase end time.
            if ($compileTotalMs -gt 0 -or $compileExit -eq 0) {
                $compStart = $timingEvents | Where-Object { $_.Type -eq "phase_start" -and $_.Name -eq "Compilation" } | Select-Object -First 1
                $compEnd = $timingEvents | Where-Object { $_.Type -eq "phase_end" -and $_.Name -eq "Compilation" } | Select-Object -Last 1
                if ($compStart -and $compEnd) {
                    $compEnd.TickMs = $compStart.TickMs + $compileTotalMs
                }
            }
        }
        if ($compileExit -eq 0 -and (Test-Path $outFile)) {
            Write-Host "PASS: Compilation completed" -ForegroundColor Green
        } else {
            Write-Host "FAIL: Compilation failed (exit $compileExit)" -ForegroundColor Red
            Write-Host "Aborting - compiled exe required for live tests" -ForegroundColor Red
            Show-TimingReport
            exit 1
        }
    } elseif (Test-Path $compilePs1) {
        # compile.ps1 not found at early launch — try now
        Record-PhaseStart "Compilation"
        Write-Host "  Running compile.ps1..."
        $compileFlags = "--test-mode"
        if ($timing) { $compileFlags += " --timing" }
        if ($forceCompile) { $compileFlags += " --force" }
        $compileOutFile = "$env:TEMP\compile_captured.log"
        Remove-Item -Force -ErrorAction SilentlyContinue $compileOutFile
        $compileExit = [SilentProcess]::RunWaitCaptured(('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $compilePs1 + '" ' + $compileFlags), $compileOutFile, $compileDir)
        Record-PhaseEnd "Compilation"
        # Parse compile.ps1 step timings from captured output
        if ($timing -and (Test-Path $compileOutFile)) {
            foreach ($line in (Get-Content $compileOutFile -ErrorAction SilentlyContinue)) {
                if ($line -match '^TIMING:(.+):(\d+)$') {
                    Record-ItemTiming -Phase "Compilation" -Item $Matches[1] -DurationMs ([double]$Matches[2])
                }
            }
        }
        if ($compileExit -eq 0 -and (Test-Path $outFile)) {
            Write-Host "PASS: Compilation completed" -ForegroundColor Green
        } else {
            Write-Host "FAIL: Compilation failed (exit $compileExit)" -ForegroundColor Red
            Write-Host "Aborting - compiled exe required for live tests" -ForegroundColor Red
            Show-TimingReport
            exit 1
        }
    } else {
        Write-Host "FAIL: compile.ps1 not found" -ForegroundColor Red
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
# so snapshot the duration now if the process has already exited.
if ($guiHandle -ne [IntPtr]::Zero) {
    $guiCode = [SilentProcess]::TryGetExitCode($guiHandle)
    if ($guiCode -ne -259) {
        $guiDurationMs = $masterSw.ElapsedMilliseconds - $guiStartTickMs
        $guiTimingRecorded = $true
    }
}

# --- Test Execution ---
$mainExitCode = 0

if ($live) {
    # === Live Test Pipeline ===
    # GUI + Unit tests already launched above (gated by pre-gate only).
    # Live tests launch here after compilation (they need the compiled exe).

    $coreLogFile = "$env:TEMP\alt_tabby_tests_core.log"
    $networkLogFile = "$env:TEMP\alt_tabby_tests_network.log"
    $featuresLogFile = "$env:TEMP\alt_tabby_tests_features.log"
    $executionLogFile = "$env:TEMP\alt_tabby_tests_execution.log"
    $lifecycleLogFile = "$env:TEMP\alt_tabby_tests_lifecycle.log"
    $coreStderrFile = "$env:TEMP\ahk_core_stderr.log"
    $networkStderrFile = "$env:TEMP\ahk_network_stderr.log"
    $featuresStderrFile = "$env:TEMP\ahk_features_stderr.log"
    $executionStderrFile = "$env:TEMP\ahk_execution_stderr.log"
    $lifecycleStderrFile = "$env:TEMP\ahk_lifecycle_stderr.log"

    # Clean live suite log files
    foreach ($f in @($coreLogFile, $networkLogFile, $featuresLogFile, $executionLogFile, $lifecycleLogFile, $coreStderrFile, $networkStderrFile, $featuresStderrFile, $executionStderrFile, $lifecycleStderrFile)) {
        Remove-Item -Force -ErrorAction SilentlyContinue $f
    }

    $liveStart = Get-Date

    # --- Live suites (5 parallel, gated by compilation) ---
    Write-Host "`n--- Live Test Execution (5 suites, parallel) ---" -ForegroundColor Yellow

    # The "Tests" phase starts at the earliest test launch (GUI + Unit, already running).
    if ($timing) {
        [void]$timingEvents.Add(@{ Type = "phase_start"; Name = "Tests"; TickMs = $guiStartTickMs })
    }

    $liveStartTickMs = $masterSw.ElapsedMilliseconds
    # If compilation finished during pre-gate, live suites launch at the same offset
    # as GUI+Unit (no meaningful stagger). Merge to avoid spurious arrows.
    if (($liveStartTickMs - $guiStartTickMs) -lt 500) {
        $liveStartTickMs = $guiStartTickMs
    }

    Write-Host "  Starting Live/Features tests (background)..." -ForegroundColor Cyan
    $featuresHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-features', $featuresStderrFile)

    Write-Host "  Starting Live/Core tests (background)..." -ForegroundColor Cyan
    $coreHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-core', $coreStderrFile)

    Write-Host "  Starting Live/Network tests (background)..." -ForegroundColor Cyan
    $networkHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-network', $networkStderrFile)

    Write-Host "  Starting Live/Execution tests (background)..." -ForegroundColor Cyan
    $executionHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-execution', $executionStderrFile)

    Write-Host "  Starting Live/Lifecycle tests (background)..." -ForegroundColor Cyan
    $lifecycleHandle = [SilentProcess]::StartCaptured('"' + $ahk + '" /ErrorStdOut "' + $script + '" --live-lifecycle', $lifecycleStderrFile)

    # --- Timing: poll all handles + GUI to record actual completion times ---
    if ($timing) {
        $suiteHandles = @{
            "Live/Features"  = $featuresHandle
            "Live/Core"      = $coreHandle
            "Live/Network"   = $networkHandle
            "Live/Execution" = $executionHandle
            "Live/Lifecycle" = $lifecycleHandle
        }
        foreach ($us in $unitSuites) {
            $suiteHandles[$us.Label] = $us.Handle
        }

        # Include GUI Tests in the poll if not already finished
        $guiInPoll = (-not $guiTimingRecorded -and $guiHandle -ne [IntPtr]::Zero)
        if ($guiInPoll) { $suiteHandles["GUI Tests"] = $guiHandle }

        $suiteDone = @{}
        # If GUI Tests already finished, record it now
        if ($guiTimingRecorded) { $suiteDone["GUI Tests"] = $guiDurationMs }

        $totalToWait = $suiteHandles.Count
        if ($guiTimingRecorded) { $totalToWait = $suiteHandles.Count + 1 }

        while ($suiteDone.Count -lt $totalToWait) {
            foreach ($name in $suiteHandles.Keys) {
                if ($suiteDone.ContainsKey($name)) { continue }
                $code = [SilentProcess]::TryGetExitCode($suiteHandles[$name])
                if ($code -ne -259) {
                    $nowMs = $masterSw.ElapsedMilliseconds
                    if ($name -eq "GUI Tests") {
                        $suiteDone[$name] = $nowMs - $guiStartTickMs
                    } elseif ($name -like "Unit/*") {
                        $suiteDone[$name] = $nowMs - $guiStartTickMs
                    } else {
                        $suiteDone[$name] = $nowMs - $liveStartTickMs
                    }
                }
            }
            if ($suiteDone.Count -lt $totalToWait) {
                Start-Sleep -Milliseconds 25
            }
        }
        Record-PhaseEnd "Tests"

        foreach ($label in $suiteDone.Keys) {
            if ($label -eq "GUI Tests" -or $label -like "Unit/*") {
                $itemOffsetMs = $guiStartTickMs
            } else {
                $itemOffsetMs = $liveStartTickMs
            }
            Record-ItemTiming -Phase "Tests" -Item $label -DurationMs $suiteDone[$label] -OffsetMs $itemOffsetMs
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

    Write-Host "`n--- Network Test Results ---" -ForegroundColor Yellow
    $networkExitCode = [SilentProcess]::WaitAndGetExitCode($networkHandle)

    $networkStderr = Get-Content $networkStderrFile -ErrorAction SilentlyContinue
    if ($networkStderr) {
        Write-Host "=== NETWORK TEST ERRORS ===" -ForegroundColor Red
        Write-Host $networkStderr
    }
    Show-TestSummary -LogPath $networkLogFile -Label "Network"

    if ($networkExitCode -ne 0) { $mainExitCode = $networkExitCode }

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

    Write-Host "`n--- Lifecycle Test Results ---" -ForegroundColor Yellow
    $lifecycleExitCode = [SilentProcess]::WaitAndGetExitCode($lifecycleHandle)

    $lifecycleStderr = Get-Content $lifecycleStderrFile -ErrorAction SilentlyContinue
    if ($lifecycleStderr) {
        Write-Host "=== LIFECYCLE TEST ERRORS ===" -ForegroundColor Red
        Write-Host $lifecycleStderr
    }
    Show-TestSummary -LogPath $lifecycleLogFile -Label "Lifecycle"

    if ($lifecycleExitCode -ne 0) { $mainExitCode = $lifecycleExitCode }

    $liveElapsed = ((Get-Date) - $liveStart).TotalSeconds
    Write-Host "`n  Live pipeline completed in $([math]::Round($liveElapsed, 1))s" -ForegroundColor Cyan
} else {
    # === Non-live mode: 5-way parallel unit tests ===
    # Note: --timing implies --live, so this path never runs with timing enabled.
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
}

# --- GUI Tests Phase (Collect Results) ---
Write-Host "`n--- GUI Tests Phase ---" -ForegroundColor Yellow

if ($guiHandle -ne [IntPtr]::Zero) {
    $guiExitCode = [SilentProcess]::WaitAndGetExitCode($guiHandle)
    if (-not $guiTimingRecorded) {
        $guiDurationMs = $masterSw.ElapsedMilliseconds - $guiStartTickMs
        $guiTimingRecorded = $true
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
