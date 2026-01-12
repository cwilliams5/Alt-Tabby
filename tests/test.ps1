# Alt-Tabby Test Runner
# Usage: .\tests\test.ps1 [--live]

param(
    [switch]$live
)

$ahk = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$script = "$PSScriptRoot\run_tests.ahk"
$logFile = "$env:TEMP\alt_tabby_tests.log"
$stderrFile = "$env:TEMP\ahk_stderr.log"

# Remove old logs
Remove-Item -Force -ErrorAction SilentlyContinue $logFile
Remove-Item -Force -ErrorAction SilentlyContinue $stderrFile

# Build arguments
$args = @("/ErrorStdOut", $script)
if ($live) {
    $args += "--live"
}

# Run AHK with error capture
$process = Start-Process -FilePath $ahk -ArgumentList $args -Wait -NoNewWindow -PassThru -RedirectStandardError $stderrFile

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

exit $process.ExitCode
