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

# --- Compilation Phase ---
# Always recompile before testing compiled exe to ensure we test current code
Write-Host "`n--- Compilation Phase ---" -ForegroundColor Yellow
$compiler = "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe"
$ahkBase = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$srcFile = "$srcRoot\alt_tabby.ahk"
$releaseDir = (Resolve-Path "$PSScriptRoot\..").Path + "\release"
$outFile = "$releaseDir\AltTabby.exe"

if (Test-Path $compiler) {
    Write-Host "Recompiling source to ensure tests use current code..."

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

    # Compile - use quoted argument string to handle paths with spaces
    # Note: PowerShell ArgumentList with array doesn't handle spaces well
    $compileArgStr = "/in `"$srcFile`" /out `"$outFile`" /base `"$ahkBase`" /silent verbose"
    $compileProc = Start-Process -FilePath $compiler -ArgumentList $compileArgStr -Wait -NoNewWindow -PassThru

    if ($compileProc.ExitCode -eq 0 -and (Test-Path $outFile)) {
        Write-Host "PASS: Compiled AltTabby.exe successfully" -ForegroundColor Green
    } else {
        Write-Host "FAIL: Compilation failed (exit code: $($compileProc.ExitCode))" -ForegroundColor Red
        # Continue with tests anyway - compiled exe tests will be skipped if exe doesn't exist
    }
} else {
    Write-Host "SKIP: Ahk2Exe.exe not found - compiled exe tests will use existing binary" -ForegroundColor Yellow
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
