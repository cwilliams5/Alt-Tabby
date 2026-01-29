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

# Launch all syntax checks in parallel
$syntaxJobs = @()
foreach ($file in $filesToCheck) {
    if (Test-Path $file) {
        $shortName = Split-Path $file -Leaf
        $errFile = "$env:TEMP\ahk_syntax_$shortName.log"
        Remove-Item -Force -ErrorAction SilentlyContinue $errFile

        # Start syntax check as background job
        $syntaxJobs += Start-Job -ScriptBlock {
            param($ahkPath, $filePath, $errFilePath)
            $proc = Start-Process -FilePath $ahkPath -ArgumentList "/ErrorStdOut", "/validate", $filePath -Wait -NoNewWindow -PassThru -RedirectStandardError $errFilePath 2>$null
            $errContent = if (Test-Path $errFilePath) { Get-Content $errFilePath -Raw -ErrorAction SilentlyContinue } else { "" }
            return @{
                ExitCode = $proc.ExitCode
                ErrorContent = $errContent
                FileName = Split-Path $filePath -Leaf
            }
        } -ArgumentList $ahk, $file, $errFile
    }
}

# Wait for all syntax checks to complete and collect results
$syntaxErrors = 0
$syntaxJobs | Wait-Job | ForEach-Object {
    $result = Receive-Job $_
    if ($result.ExitCode -ne 0 -and $result.ErrorContent) {
        Write-Host "FAIL: $($result.FileName)" -ForegroundColor Red
        Write-Host $result.ErrorContent -ForegroundColor Red
        $syntaxErrors++
    } else {
        Write-Host "PASS: $($result.FileName)" -ForegroundColor Green
    }
    Remove-Job $_
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
$guiStderrFile = "$env:TEMP\ahk_gui_stderr.log"
$guiJob = $null

Remove-Item -Force -ErrorAction SilentlyContinue $guiLogFile
Remove-Item -Force -ErrorAction SilentlyContinue $guiStderrFile

if (Test-Path $guiScript) {
    Write-Host "Starting GUI tests in background..." -ForegroundColor Cyan
    $guiJob = Start-Job -ScriptBlock {
        param($ahkPath, $scriptPath, $stderrPath)
        $proc = Start-Process -FilePath $ahkPath -ArgumentList "/ErrorStdOut", $scriptPath -Wait -NoNewWindow -PassThru -RedirectStandardError $stderrPath
        return $proc.ExitCode
    } -ArgumentList $ahk, $guiScript, $guiStderrFile
}

if ($live) {
    Write-Host "`n--- Compilation Phase ---" -ForegroundColor Yellow
    Write-Host "SKIP: Compilation deferred to Core tests (--live)" -ForegroundColor Cyan
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
        }
    } else {
        Write-Host "SKIP: Ahk2Exe.exe not found - compiled exe tests will use existing binary" -ForegroundColor Yellow
    }
}

# --- Test Execution ---
$mainExitCode = 0

if ($live) {
    # === Parallel Live Test Mode ===
    # 1. Run unit tests (no --live flag)
    # 2. Run Core + Features in parallel
    # 3. Run Execution sequentially (needs compiled exe from Core)

    Write-Host "`n--- Unit Tests Phase ---" -ForegroundColor Yellow
    $unitArgs = @("/ErrorStdOut", $script)
    $process = Start-Process -FilePath $ahk -ArgumentList $unitArgs -Wait -NoNewWindow -PassThru -RedirectStandardError $stderrFile

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

    if ($process.ExitCode -ne 0) {
        $mainExitCode = $process.ExitCode
    }

    # --- Parallel Live Suites: Core + Features ---
    Write-Host "`n--- Live Tests Phase (Core + Features in parallel) ---" -ForegroundColor Yellow

    $coreLogFile = "$env:TEMP\alt_tabby_tests_core.log"
    $featuresLogFile = "$env:TEMP\alt_tabby_tests_features.log"
    $executionLogFile = "$env:TEMP\alt_tabby_tests_execution.log"
    $coreStderrFile = "$env:TEMP\ahk_core_stderr.log"
    $featuresStderrFile = "$env:TEMP\ahk_features_stderr.log"
    $executionStderrFile = "$env:TEMP\ahk_execution_stderr.log"

    # Clean parallel log files
    Remove-Item -Force -ErrorAction SilentlyContinue $coreLogFile
    Remove-Item -Force -ErrorAction SilentlyContinue $featuresLogFile
    Remove-Item -Force -ErrorAction SilentlyContinue $executionLogFile
    Remove-Item -Force -ErrorAction SilentlyContinue $coreStderrFile
    Remove-Item -Force -ErrorAction SilentlyContinue $featuresStderrFile
    Remove-Item -Force -ErrorAction SilentlyContinue $executionStderrFile

    $coreStart = Get-Date
    Write-Host "  Starting Core tests..." -ForegroundColor Cyan
    $coreJob = Start-Job -ScriptBlock {
        param($ahkPath, $scriptPath, $stderrPath)
        $proc = Start-Process -FilePath $ahkPath -ArgumentList "/ErrorStdOut", $scriptPath, "--live-core" -Wait -NoNewWindow -PassThru -RedirectStandardError $stderrPath
        return $proc.ExitCode
    } -ArgumentList $ahk, $script, $coreStderrFile

    Write-Host "  Starting Features tests..." -ForegroundColor Cyan
    $featuresJob = Start-Job -ScriptBlock {
        param($ahkPath, $scriptPath, $stderrPath)
        $proc = Start-Process -FilePath $ahkPath -ArgumentList "/ErrorStdOut", $scriptPath, "--live-features" -Wait -NoNewWindow -PassThru -RedirectStandardError $stderrPath
        return $proc.ExitCode
    } -ArgumentList $ahk, $script, $featuresStderrFile

    # Wait for both to complete
    Write-Host "  Waiting for Core + Features to complete..." -ForegroundColor DarkGray
    $coreExitCode = $coreJob | Wait-Job | Receive-Job
    Remove-Job $coreJob
    $featuresExitCode = $featuresJob | Wait-Job | Receive-Job
    Remove-Job $featuresJob

    $parallelElapsed = ((Get-Date) - $coreStart).TotalSeconds

    # Show Core results
    Write-Host "`n--- Core Test Results ---" -ForegroundColor Yellow
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

    # Show Features results
    Write-Host "`n--- Features Test Results ---" -ForegroundColor Yellow
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

    Write-Host "`n  Core + Features completed in $([math]::Round($parallelElapsed, 1))s (parallel)" -ForegroundColor Cyan

    if ($coreExitCode -ne 0) { $mainExitCode = $coreExitCode }
    if ($featuresExitCode -ne 0) { $mainExitCode = $featuresExitCode }

    # --- Sequential: Execution tests (needs compiled exe from Core) ---
    Write-Host "`n--- Execution Tests Phase (sequential) ---" -ForegroundColor Yellow
    $execStart = Get-Date
    $execProcess = Start-Process -FilePath $ahk -ArgumentList "/ErrorStdOut", $script, "--live-execution" -Wait -NoNewWindow -PassThru -RedirectStandardError $executionStderrFile

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

    $execElapsed = ((Get-Date) - $execStart).TotalSeconds
    Write-Host "`n  Execution tests completed in $([math]::Round($execElapsed, 1))s" -ForegroundColor Cyan

    if ($execProcess.ExitCode -ne 0) { $mainExitCode = $execProcess.ExitCode }
} else {
    # === Non-live mode: unit tests only ===
    Write-Host "`n--- Unit Tests Phase ---" -ForegroundColor Yellow

    $testArgs = @("/ErrorStdOut", $script)
    $process = Start-Process -FilePath $ahk -ArgumentList $testArgs -Wait -NoNewWindow -PassThru -RedirectStandardError $stderrFile

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

    $mainExitCode = $process.ExitCode
}

# --- GUI Tests Phase (Collect Results) ---
Write-Host "`n--- GUI Tests Phase ---" -ForegroundColor Yellow

if ($guiJob) {
    Write-Host "Waiting for GUI tests to complete..."
    $guiExitCode = $guiJob | Wait-Job | Receive-Job
    Remove-Job $guiJob

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

    if ($guiExitCode -ne 0) {
        $mainExitCode = $guiExitCode
    }
} else {
    Write-Host "SKIP: gui_tests.ahk not found" -ForegroundColor Yellow
}

exit $mainExitCode
