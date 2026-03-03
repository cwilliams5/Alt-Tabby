# shader_compile.ps1 — Compile HLSL shaders to pre-compiled DXBC bytecode
#
# Input:  src/shaders/*.hlsl + vertex shader (inline)
# Output: resources/shaders/ps_<key>.bin + resources/shaders/vs_VSMain.bin
#
# Per-shader staleness: only recompiles when HLSL is newer than .bin.
# Cleans stale .bin files for removed shaders.
#
# Usage: powershell -File tools/shader_compile.ps1 [--force]

param(
    [switch]$force
)

$ErrorActionPreference = 'Stop'

# Resolve paths relative to repo root (script lives in tools/)
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$shaderDir = Join-Path $repoRoot 'src\shaders'
$outputDir = Join-Path $repoRoot 'resources\shaders'
$workerScript = Join-Path $repoRoot 'tools\shader_compile_worker.ahk'
$ahk2base = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

# Ensure output directory exists
if (!(Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

# === Discover HLSL files ===
$hlslFiles = @(Get-ChildItem -Path $shaderDir -Filter '*.hlsl' -ErrorAction SilentlyContinue | Sort-Object Name)
if ($hlslFiles.Count -eq 0) {
    Write-Host "No .hlsl files found in $shaderDir"
    exit 0
}

# Build shader key from filename (same normalization as shader_bundle.ps1)
function Get-ShaderKey($baseName) {
    $funcName = ($baseName -split '[_\-]' | ForEach-Object {
        $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower()
    }) -join ''
    return $funcName.Substring(0,1).ToLower() + $funcName.Substring(1)
}

# === Check staleness for each shader ===
$staleShaders = @()
$cachedCount = 0
$totalPS = $hlslFiles.Count
$totalVS = 1  # VSMain
$totalShaders = $totalPS + $totalVS

Write-Host "Scanning $totalShaders shaders ($totalPS PS + $totalVS VS)..."

foreach ($hlsl in $hlslFiles) {
    $key = Get-ShaderKey $hlsl.BaseName
    $binPath = Join-Path $outputDir "ps_$key.bin"

    if (!$force -and (Test-Path $binPath)) {
        $binTime = (Get-Item $binPath).LastWriteTime
        $hlslTime = $hlsl.LastWriteTime
        if ($binTime -gt $hlslTime) {
            $cachedCount++
            continue
        }
    }

    $staleShaders += @{
        Key      = $key
        HlslPath = $hlsl.FullName
        BinPath  = $binPath
        Entry    = "PSMain"
        Target   = "ps_4_0"
    }
}

# Check VS staleness — VS source is inline (hardcoded), so we use the worker script's
# own timestamp as the "source" for staleness. If --force, always recompile.
$vsBinPath = Join-Path $outputDir "vs_VSMain.bin"
$vsHlslPath = Join-Path $repoRoot 'tools\vs_fullscreen.hlsl'

# Write the VS HLSL to a temp file for the worker to compile
$vsHlslContent = @"
struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };
VSOut VSMain(uint id : SV_VertexID) {
    VSOut o;
    o.uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(o.uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}
"@

$vsNeedsCompile = $force -or !(Test-Path $vsBinPath)
if (!$vsNeedsCompile) {
    # VS source is constant — only recompile on --force or if .bin is missing
    # But if worker script changed, that's not relevant (VS HLSL is inline constant)
    $cachedCount++
} else {
    # Write VS HLSL to temp file for worker
    $vsTempHlsl = Join-Path ([IO.Path]::GetTempPath()) "alttabby_vs_main.hlsl"
    [IO.File]::WriteAllText($vsTempHlsl, $vsHlslContent, [System.Text.UTF8Encoding]::new($false))
    $staleShaders += @{
        Key      = "VSMain"
        HlslPath = $vsTempHlsl
        BinPath  = $vsBinPath
        Entry    = "VSMain"
        Target   = "vs_4_0"
    }
}

# === Nothing to compile? ===
if ($staleShaders.Count -eq 0) {
    Write-Host "  All $totalShaders shaders up to date."
    # Still do stale cleanup
} else {
    Write-Host "  $cachedCount cached, $($staleShaders.Count) to compile"

    # === Write manifest for worker ===
    $manifestPath = Join-Path ([IO.Path]::GetTempPath()) "alttabby_shader_manifest_$([Guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    $manifestLines = @()
    foreach ($s in $staleShaders) {
        $manifestLines += "$($s.HlslPath)|$($s.BinPath)|$($s.Entry)|$($s.Target)"
    }
    [IO.File]::WriteAllLines($manifestPath, $manifestLines)

    # === Invoke worker ===
    if (!(Test-Path $ahk2base)) {
        Write-Host "ERROR: AutoHotkey v2 not found at: $ahk2base" -ForegroundColor Red
        exit 1
    }
    if (!(Test-Path $workerScript)) {
        Write-Host "ERROR: Worker script not found: $workerScript" -ForegroundColor Red
        exit 1
    }

    $proc = Start-Process -FilePath $ahk2base -ArgumentList "/ErrorStdOut `"$workerScript`" `"$manifestPath`"" `
        -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput "$manifestPath.out" -RedirectStandardError "$manifestPath.err"

    # Display worker output
    if (Test-Path "$manifestPath.out") {
        $workerOutput = Get-Content "$manifestPath.out" -Raw
        if ($workerOutput) {
            # Parse output for reporting
            $lines = $workerOutput -split "`r?`n" | Where-Object { $_ -ne '' }
            foreach ($line in $lines) {
                if ($line -match '^OK ') {
                    $shortName = [IO.Path]::GetFileNameWithoutExtension(($line -replace '^OK\s+', '' -replace '\s+\(.*$', ''))
                    $sizeInfo = ''
                    if ($line -match '\(([^)]+)\)') { $sizeInfo = " ($($Matches[1]))" }
                    Write-Host "  NEW  $shortName$sizeInfo"
                } elseif ($line -match '^FAIL') {
                    Write-Host "  $line" -ForegroundColor Red
                } elseif ($line -match '^SUMMARY') {
                    # Skip — we'll report our own summary
                } else {
                    Write-Host "  $line"
                }
            }
        }
        Remove-Item "$manifestPath.out" -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path "$manifestPath.err") {
        $errContent = Get-Content "$manifestPath.err" -Raw
        if ($errContent) { Write-Host $errContent -ForegroundColor Red }
        Remove-Item "$manifestPath.err" -Force -ErrorAction SilentlyContinue
    }

    # Cleanup
    Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue
    if ($vsTempHlsl -and (Test-Path $vsTempHlsl)) {
        Remove-Item $vsTempHlsl -Force -ErrorAction SilentlyContinue
    }

    # Check worker exit code (= number of failures)
    if ($proc.ExitCode -ne 0) {
        Write-Host ""
        Write-Host "ERROR: $($proc.ExitCode) shader(s) failed to compile." -ForegroundColor Red
        exit 1
    }
}

# === Clean stale .bin files ===
# Build set of expected .bin filenames
$expectedBins = @{}
$expectedBins["vs_VSMain.bin"] = $true
foreach ($hlsl in $hlslFiles) {
    $key = Get-ShaderKey $hlsl.BaseName
    $expectedBins["ps_$key.bin"] = $true
}

$staleRemoved = 0
$existingBins = @(Get-ChildItem -Path $outputDir -Filter '*.bin' -ErrorAction SilentlyContinue)
foreach ($bin in $existingBins) {
    if (-not $expectedBins.ContainsKey($bin.Name)) {
        Remove-Item $bin.FullName -Force
        Write-Host "  CLEAN $($bin.Name) (shader removed)"
        $staleRemoved++
    }
}

# === Validate final count ===
$finalBins = @(Get-ChildItem -Path $outputDir -Filter '*.bin' -ErrorAction SilentlyContinue)
if ($finalBins.Count -ne $totalShaders) {
    Write-Host ""
    Write-Host "ERROR: Expected $totalShaders .bin files, found $($finalBins.Count)" -ForegroundColor Red
    # List what's missing
    foreach ($hlsl in $hlslFiles) {
        $key = Get-ShaderKey $hlsl.BaseName
        $binPath = Join-Path $outputDir "ps_$key.bin"
        if (!(Test-Path $binPath)) {
            Write-Host "  MISSING: ps_$key.bin" -ForegroundColor Red
        }
    }
    if (!(Test-Path $vsBinPath)) {
        Write-Host "  MISSING: vs_VSMain.bin" -ForegroundColor Red
    }
    exit 1
}

# === Validate DXBC magic bytes ===
$magicFailures = 0
foreach ($bin in $finalBins) {
    $bytes = [IO.File]::ReadAllBytes($bin.FullName)
    # DXBC magic: 0x44='D', 0x58='X', 0x42='B', 0x43='C'
    if ($bytes.Length -lt 4 -or $bytes[0] -ne 0x44 -or $bytes[1] -ne 0x58 -or $bytes[2] -ne 0x42 -or $bytes[3] -ne 0x43) {
        Write-Host "  CORRUPT: $($bin.Name) - missing DXBC magic bytes" -ForegroundColor Red
        $magicFailures++
    }
}
if ($magicFailures -gt 0) {
    Write-Host "ERROR: $magicFailures .bin file(s) have invalid DXBC headers" -ForegroundColor Red
    exit 1
}

# === Summary ===
$compiledCount = $staleShaders.Count
$cleanMsg = ""
if ($staleRemoved) { $cleanMsg = ", $staleRemoved cleaned" }
Write-Host "  $cachedCount cached, $compiledCount compiled$cleanMsg. $($finalBins.Count)/$totalShaders OK."
exit 0
