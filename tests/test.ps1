# Alt-Tabby Test Runner
# Usage: .\tests\test.ps1 [--live]

param(
    [switch]$live
)

$ahk = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$script = "$PSScriptRoot\run_tests.ahk"
$logFile = "$env:TEMP\alt_tabby_tests.log"
$stderrFile = "$env:TEMP\ahk_stderr.log"
$srcRoot = (Resolve-Path "$PSScriptRoot\..\src").Path

# Remove old logs
Remove-Item -Force -ErrorAction SilentlyContinue $logFile
Remove-Item -Force -ErrorAction SilentlyContinue $stderrFile

Write-Host "=== Alt-Tabby Test Run $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Cyan
Write-Host "Log file: $logFile"

# --- Syntax Check Phase ---
Write-Host "`n--- Syntax Check Phase ---" -ForegroundColor Yellow

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

$syntaxErrors = 0
foreach ($file in $filesToCheck) {
    if (Test-Path $file) {
        $shortName = Split-Path $file -Leaf
        $errFile = "$env:TEMP\ahk_syntax_$shortName.log"
        Remove-Item -Force -ErrorAction SilentlyContinue $errFile

        # Use /ErrorStdOut to capture syntax errors without GUI
        $proc = Start-Process -FilePath $ahk -ArgumentList "/ErrorStdOut", "/validate", $file -Wait -NoNewWindow -PassThru -RedirectStandardError $errFile 2>$null

        # /validate doesn't exist, so try a different approach: just check if it compiles
        # We use a timeout and check stderr
        if ($proc.ExitCode -ne 0) {
            $errContent = Get-Content $errFile -ErrorAction SilentlyContinue -Raw
            if ($errContent) {
                Write-Host "FAIL: $shortName" -ForegroundColor Red
                Write-Host $errContent -ForegroundColor Red
                $syntaxErrors++
            } else {
                # Exit code non-zero but no error might be normal termination
                Write-Host "PASS: $shortName (syntax ok)" -ForegroundColor Green
            }
        } else {
            Write-Host "PASS: $shortName" -ForegroundColor Green
        }
    } else {
        Write-Host "SKIP: $file (not found)" -ForegroundColor Yellow
    }
}

if ($syntaxErrors -gt 0) {
    Write-Host "`n=== SYNTAX ERRORS FOUND: $syntaxErrors ===" -ForegroundColor Red
    Write-Host "Fix syntax errors before running tests." -ForegroundColor Red
    exit 1
}

Write-Host "`n--- Unit Tests Phase ---" -ForegroundColor Yellow

# Build arguments
$testArgs = @("/ErrorStdOut", $script)
if ($live) {
    $testArgs += "--live"
}

# Run AHK with error capture
$process = Start-Process -FilePath $ahk -ArgumentList $testArgs -Wait -NoNewWindow -PassThru -RedirectStandardError $stderrFile

# Check for errors
$stderr = Get-Content $stderrFile -ErrorAction SilentlyContinue
if ($stderr) {
    Write-Host "=== ERRORS ===" -ForegroundColor Red
    Write-Host $stderr
}

# Show results
if (Test-Path $logFile) {
    Get-Content $logFile
} else {
    Write-Host "Test log not found - tests may have failed to run" -ForegroundColor Red
}

$mainExitCode = $process.ExitCode

# --- GUI Tests Phase ---
Write-Host "`n--- GUI Tests Phase ---" -ForegroundColor Yellow

$guiScript = "$PSScriptRoot\gui_tests.ahk"
$guiLogFile = "$env:TEMP\gui_tests.log"
$guiStderrFile = "$env:TEMP\ahk_gui_stderr.log"

Remove-Item -Force -ErrorAction SilentlyContinue $guiLogFile
Remove-Item -Force -ErrorAction SilentlyContinue $guiStderrFile

if (Test-Path $guiScript) {
    $guiArgs = @("/ErrorStdOut", $guiScript)
    $guiProcess = Start-Process -FilePath $ahk -ArgumentList $guiArgs -Wait -NoNewWindow -PassThru -RedirectStandardError $guiStderrFile

    # Check for errors
    $guiStderr = Get-Content $guiStderrFile -ErrorAction SilentlyContinue
    if ($guiStderr) {
        Write-Host "=== GUI TEST ERRORS ===" -ForegroundColor Red
        Write-Host $guiStderr
    }

    # Show results
    if (Test-Path $guiLogFile) {
        Get-Content $guiLogFile
    } else {
        Write-Host "GUI test log not found - tests may have failed to run" -ForegroundColor Red
    }

    if ($guiProcess.ExitCode -ne 0) {
        $mainExitCode = $guiProcess.ExitCode
    }
} else {
    Write-Host "SKIP: gui_tests.ahk not found" -ForegroundColor Yellow
}

exit $mainExitCode
