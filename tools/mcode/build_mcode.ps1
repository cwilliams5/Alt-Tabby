#
# build_mcode.ps1 — Unified MCode build pipeline
#
# Compiles C source to .obj via MSVC, then extracts MCode via COFFReader.
#
# Usage:
#   .\tools\mcode\build_mcode.ps1 -Source <path.c> [-Arch <x64|x86|both>] [-ImportDlls <dll1,dll2>]
#
# Examples:
#   .\tools\mcode\build_mcode.ps1 -Source tools\native_benchmark\native_src\icon_alpha.c
#   .\tools\mcode\build_mcode.ps1 -Source my_func.c -Arch x64 -ImportDlls kernel32,user32
#
param(
    [Parameter(Mandatory=$true)]
    [string]$Source,

    [ValidateSet("x64", "x86", "both")]
    [string]$Arch = "both",

    [string]$ImportDlls = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Resolve source path
$Source = Resolve-Path $Source -ErrorAction Stop

# Find vswhere to locate MSVC
function Find-VsWhere {
    $paths = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Find-VcVarsAll {
    $vswhere = Find-VsWhere
    if ($vswhere) {
        $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
        if ($installPath) {
            $vcvars = Join-Path $installPath "VC\Auxiliary\Build\vcvarsall.bat"
            if (Test-Path $vcvars) { return $vcvars }
        }
    }

    # Fallback: hardcoded VS2022 Community path
    $fallback = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
    if (Test-Path $fallback) { return $fallback }

    throw "Could not find vcvarsall.bat. Install Visual Studio Build Tools with C++ workload."
}

function Find-AHK {
    # Try PATH first
    $ahk = Get-Command "AutoHotkey64.exe" -ErrorAction SilentlyContinue
    if ($ahk) { return $ahk.Source }

    # Standard install location
    $standard = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
    if (Test-Path $standard) { return $standard }

    throw "Could not find AutoHotkey64.exe. Install AutoHotkey v2."
}

function Compile-Obj {
    param([string]$SourceFile, [string]$ArchTarget, [string]$OutputObj)

    $vcvars = Find-VcVarsAll

    $bat = @"
@echo off
call "$vcvars" $ArchTarget >nul 2>&1
if errorlevel 1 (
    echo VCVARS_FAILED
    exit /b 1
)
cl /O2 /c /GS- /Zl /nologo "$SourceFile" /Fo:"$OutputObj"
if errorlevel 1 (
    echo COMPILE_FAILED
    exit /b 1
)
echo COMPILE_OK
"@

    $tmpBat = Join-Path $env:TEMP "build_mcode_compile.bat"
    Set-Content $tmpBat $bat -Encoding ASCII
    $output = cmd.exe /c $tmpBat 2>&1 | Out-String
    Remove-Item $tmpBat -Force -ErrorAction SilentlyContinue

    if ($output -match "VCVARS_FAILED") {
        throw "Failed to initialize MSVC environment for $ArchTarget"
    }
    if ($output -match "COMPILE_FAILED" -or -not (Test-Path $OutputObj)) {
        Write-Host $output
        throw "Compilation failed for $ArchTarget"
    }

    Write-Host "  Compiled $ArchTarget -> $(Split-Path -Leaf $OutputObj)"
}

function Extract-MCode {
    param([string]$ObjFile, [string]$Imports)

    $ahk = Find-AHK
    $extractScript = Join-Path $scriptDir "extract_mcode.ahk"

    $args = @("/ErrorStdOut", $extractScript, $ObjFile)
    if ($Imports) {
        $args += $Imports
    }

    $output = & $ahk @args 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host $output
        throw "MCode extraction failed"
    }

    return $output
}

# --- Main ---

$sourceName = [System.IO.Path]::GetFileNameWithoutExtension($Source)
$tempDir = Join-Path $env:TEMP "build_mcode"
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

$archTargets = switch ($Arch) {
    "x64"  { @("x64") }
    "x86"  { @("x86") }
    "both" { @("x64", "x86") }
}

Write-Host ""
Write-Host "=== MCode Build Pipeline ==="
Write-Host "Source: $Source"
Write-Host "Arch:   $($archTargets -join ', ')"
if ($ImportDlls) { Write-Host "Imports: $ImportDlls" }
Write-Host ""

foreach ($target in $archTargets) {
    $objFile = Join-Path $tempDir "${sourceName}_${target}.obj"

    Write-Host "--- $target ---"

    # Compile
    Compile-Obj -SourceFile $Source -ArchTarget $target -OutputObj $objFile

    # Extract
    Write-Host "  Extracting MCode..."
    $output = Extract-MCode -ObjFile $objFile -Imports $ImportDlls

    Write-Host ""
    Write-Host "=== ${target} OUTPUT ==="
    Write-Host $output
    Write-Host ""
}

Write-Host "=== Done ==="
Write-Host ""
Write-Host "Paste the BASE64 blob(s) into your AHK wrapper class configs object."
Write-Host "See tools/mcode/MCODE_PIPELINE.md for details."
