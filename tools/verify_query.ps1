# verify_query.ps1 - Golden output capture and verification for query tools
#
# Captures "golden" output before internal changes, then verifies output
# is unchanged after. Essential for /review-tool-speed where all changes
# must be internal-only (no output/contract changes).
#
# Usage:
#   powershell -File tools/verify_query.ps1 -Capture           (save golden to temp dir)
#   powershell -File tools/verify_query.ps1 -Verify <dir>      (compare against golden)
#
# Workflow:
#   1. Run -Capture before making changes (prints golden dir path)
#   2. Make optimization changes
#   3. Run -Verify <golden-dir> to confirm output unchanged

param(
    [switch]$Capture,
    [string]$Verify
)

$ErrorActionPreference = 'Stop'

# === Test cases: multiple modes per tool to exercise different code paths ===
# Each entry: tool, args, output filename
$testCases = @(
    # query_state: index + specific branch
    @{ Tool = 'query_state.ps1';                Args = @();                         Out = 'state_index.txt' },
    @{ Tool = 'query_state.ps1';                Args = @('ACTIVE', 'TAB_STEP');     Out = 'state_branch.txt' },

    # query_mutations: full analysis
    @{ Tool = 'query_mutations.ps1';            Args = @('gGUI_State');             Out = 'mutations.txt' },

    # query_events: index + query + emitters
    @{ Tool = 'query_events.ps1';               Args = @();                         Out = 'events_index.txt' },
    @{ Tool = 'query_events.ps1';               Args = @('focus');                  Out = 'events_query.txt' },
    @{ Tool = 'query_events.ps1';               Args = @('-Emitters');              Out = 'events_emitters.txt' },

    # query_impact: blast radius
    @{ Tool = 'query_impact.ps1';               Args = @('GUI_Repaint');            Out = 'impact.txt' },

    # query_callchain: forward + reverse
    @{ Tool = 'query_callchain.ps1';            Args = @('GUI_Repaint');            Out = 'callchain_fwd.txt' },
    @{ Tool = 'query_callchain.ps1';            Args = @('GUI_Repaint', '-Reverse'); Out = 'callchain_rev.txt' },

    # query_visibility: full scan
    @{ Tool = 'query_visibility.ps1';           Args = @();                         Out = 'visibility.txt' },

    # query_function_visibility: single function
    @{ Tool = 'query_function_visibility.ps1';  Args = @('GUI_Repaint');            Out = 'funcvis.txt' },

    # query_global_ownership: single global
    @{ Tool = 'query_global_ownership.ps1';     Args = @('gGUI_State');             Out = 'ownership.txt' },

    # query_config: index + search + section
    @{ Tool = 'query_config.ps1';               Args = @();                         Out = 'config_index.txt' },
    @{ Tool = 'query_config.ps1';               Args = @('theme');                  Out = 'config_search.txt' },

    # query_function: body extraction
    @{ Tool = 'query_function.ps1';             Args = @('GUI_Repaint');            Out = 'function.txt' },

    # query_interface: file interface
    @{ Tool = 'query_interface.ps1';            Args = @('gui_state.ahk');          Out = 'interface.txt' },

    # query_timers: all timers
    @{ Tool = 'query_timers.ps1';               Args = @();                         Out = 'timers.txt' },

    # query_includes: dependency tree
    @{ Tool = 'query_includes.ps1';             Args = @('gui_state.ahk');          Out = 'includes.txt' },

    # query_ipc: message flow
    @{ Tool = 'query_ipc.ps1';                  Args = @('IPC_MSG_SNAPSHOT');       Out = 'ipc.txt' },

    # query_messages: windows messages
    @{ Tool = 'query_messages.ps1';             Args = @('0x0312');                 Out = 'messages.txt' },

    # query_instrumentation: profiler coverage
    @{ Tool = 'query_instrumentation.ps1';      Args = @();                         Out = 'instrumentation.txt' },

    # query_shader: shader metadata
    @{ Tool = 'query_shader.ps1';               Args = @();                         Out = 'shader.txt' }
)

# Lines matching these patterns are stripped before comparison (timing varies between runs)
$stripPatterns = 'Completed in \d+ms|Scanning \d+ source|pass1:\s*\d+ms|pass2:\s*\d+ms'

function Run-Tool {
    param([string]$Tool, [string[]]$ToolArgs)
    $script = Join-Path $PSScriptRoot $Tool
    if ($ToolArgs.Count -gt 0) {
        return & powershell -NoProfile -File $script @ToolArgs 2>&1
    } else {
        return & powershell -NoProfile -File $script 2>&1
    }
}

function Strip-TimingLines {
    param($Lines)
    return $Lines | Where-Object { $_ -notmatch $stripPatterns }
}

# === Coverage check: detect stale table vs actual query_*.ps1 files ===
$knownTools = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($tc in $testCases) { [void]$knownTools.Add($tc.Tool) }

$actualFiles = Get-ChildItem $PSScriptRoot -Filter "query_*.ps1" | ForEach-Object { $_.Name }

foreach ($f in $actualFiles) {
    if (-not $knownTools.Contains($f)) {
        Write-Host "  NOTE: Uncovered query tool '$f' - add to test cases?" -ForegroundColor Yellow
    }
}
foreach ($tool in $knownTools) {
    if (-not (Test-Path (Join-Path $PSScriptRoot $tool))) {
        Write-Host "  NOTE: Expected query tool '$tool' missing - remove from test cases?" -ForegroundColor Yellow
    }
}

# === Capture mode ===
if ($Capture) {
    $goldenDir = Join-Path ([System.IO.Path]::GetTempPath()) "query_golden_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    [void][System.IO.Directory]::CreateDirectory($goldenDir)

    Write-Host ""
    Write-Host "  === Capturing Golden Output ===" -ForegroundColor Cyan
    Write-Host "  Dir: $goldenDir" -ForegroundColor DarkGray
    Write-Host ""

    $captured = 0
    $skipped = 0

    foreach ($tc in $testCases) {
        $script = Join-Path $PSScriptRoot $tc.Tool
        if (-not (Test-Path $script)) {
            Write-Host "  SKIP $($tc.Tool) - not found" -ForegroundColor Red
            $skipped++
            continue
        }

        $argLabel = if ($tc.Args.Count -gt 0) { " " + ($tc.Args -join ' ') } else { "" }
        Write-Host "  $($tc.Tool)$argLabel -> $($tc.Out)" -NoNewline -ForegroundColor White

        $output = Run-Tool $tc.Tool $tc.Args
        $filtered = Strip-TimingLines $output
        $filtered | Out-File (Join-Path $goldenDir $tc.Out) -Encoding utf8
        $captured++

        Write-Host " OK" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  Captured $captured test cases ($skipped skipped)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Golden dir: $goldenDir" -ForegroundColor White
    Write-Host "  To verify:  powershell -File tools/verify_query.ps1 -Verify `"$goldenDir`"" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# === Verify mode ===
if ($Verify) {
    if (-not (Test-Path $Verify)) {
        Write-Host "  ERROR: Golden directory not found: $Verify" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "  === Verifying Against Golden Output ===" -ForegroundColor Cyan
    Write-Host "  Golden: $Verify" -ForegroundColor DarkGray
    Write-Host ""

    $passed = 0
    $failed = 0
    $skipped = 0
    $failures = [System.Collections.ArrayList]::new()

    foreach ($tc in $testCases) {
        $goldenFile = Join-Path $Verify $tc.Out
        if (-not (Test-Path $goldenFile)) {
            $skipped++
            continue
        }

        $script = Join-Path $PSScriptRoot $tc.Tool
        if (-not (Test-Path $script)) {
            $skipped++
            continue
        }

        $argLabel = if ($tc.Args.Count -gt 0) { " " + ($tc.Args -join ' ') } else { "" }

        $output = Run-Tool $tc.Tool $tc.Args
        $filtered = Strip-TimingLines $output
        $golden = Get-Content $goldenFile -Encoding utf8

        $diff = Compare-Object $golden $filtered

        if ($diff) {
            Write-Host "  FAIL  $($tc.Tool)$argLabel" -ForegroundColor Red
            $failed++
            [void]$failures.Add(@{
                Label = "$($tc.Tool)$argLabel"
                Diff  = $diff | Select-Object -First 3
            })
        } else {
            Write-Host "  PASS  $($tc.Tool)$argLabel" -ForegroundColor Green
            $passed++
        }
    }

    # Show failure details
    if ($failures.Count -gt 0) {
        Write-Host ""
        Write-Host "  === Failure Details ===" -ForegroundColor Red
        foreach ($f in $failures) {
            Write-Host "  $($f.Label):" -ForegroundColor Yellow
            foreach ($d in $f.Diff) {
                $marker = if ($d.SideIndicator -eq '<=') { "expected" } else { "actual" }
                Write-Host "    ${marker}: $($d.InputObject)" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host ""
    $total = $passed + $failed
    if ($failed -eq 0) {
        Write-Host "  ALL $total TESTS PASSED" -ForegroundColor Green
    } else {
        Write-Host "  $failed/$total FAILED ($skipped skipped)" -ForegroundColor Red
    }
    Write-Host ""
    exit $(if ($failed -gt 0) { 1 } else { 0 })
}

# === No mode specified ===
Write-Host ""
Write-Host "  Usage:" -ForegroundColor Yellow
Write-Host "    verify_query.ps1 -Capture           Save golden output (before changes)" -ForegroundColor DarkGray
Write-Host "    verify_query.ps1 -Verify <dir>      Compare against golden (after changes)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Workflow:" -ForegroundColor White
Write-Host "    1. -Capture before making changes" -ForegroundColor DarkGray
Write-Host "    2. Make internal optimizations" -ForegroundColor DarkGray
Write-Host "    3. -Verify <golden-dir> to confirm output unchanged" -ForegroundColor DarkGray
Write-Host ""
exit 1
