$ErrorActionPreference = "Continue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Find vcvarsall
$vcvars = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
if (-not (Test-Path $vcvars)) {
    Write-Error "vcvarsall.bat not found at: $vcvars"
    exit 1
}

Write-Host "Setting up MSVC x64 environment..."

# Run vcvarsall and capture environment, then compile
$buildCmd = @"
@echo off
call "$vcvars" x64
cd /d "$scriptDir"
echo --- Compiling icon_alpha.c ---
cl /O2 /LD /nologo icon_alpha.c /Fe:icon_alpha.dll
echo --- Exit code: %ERRORLEVEL% ---
dir icon_alpha.* 2>nul
"@

$tempBat = Join-Path $scriptDir "_build_temp.bat"
Set-Content $tempBat $buildCmd -Encoding ASCII

$output = cmd.exe /c $tempBat 2>&1 | Out-String
Write-Host $output

Remove-Item $tempBat -Force -ErrorAction SilentlyContinue

if (Test-Path (Join-Path $scriptDir "icon_alpha.dll")) {
    Write-Host "BUILD SUCCESS" -ForegroundColor Green
} else {
    Write-Host "BUILD FAILED" -ForegroundColor Red
    exit 1
}
