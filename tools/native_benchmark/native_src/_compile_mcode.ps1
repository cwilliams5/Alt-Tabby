# LEGACY — See tools/mcode/build_mcode.ps1 for the current pipeline.
$ErrorActionPreference = "Continue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$bat = @"
@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul 2>&1
cd /d "$scriptDir"
cl /O2 /c /GS- /Zl /nologo icon_alpha.c /Fo:icon_alpha_mcode.obj
if errorlevel 1 (
    echo COMPILE_FAILED
    exit /b 1
)
echo COMPILE_OK
dumpbin /disasm icon_alpha_mcode.obj
"@

$tmpBat = Join-Path $env:TEMP "compile_mcode.bat"
Set-Content $tmpBat $bat -Encoding ASCII
$output = cmd.exe /c $tmpBat 2>&1 | Out-String
Remove-Item $tmpBat -Force -ErrorAction SilentlyContinue
Write-Host $output
