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

# === Discover HLSL files (recursive — includes mouse/, selection/ subdirs) ===
$hlslFiles = @(Get-ChildItem -Path $shaderDir -Filter '*.hlsl' -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'alt_tabby_common.hlsl' } | Sort-Object FullName)
if ($hlslFiles.Count -eq 0) {
    Write-Host "No .hlsl files found in $shaderDir"
    exit 0
}

# Build shader key from filename + optional subdir prefix (same normalization as shader_bundle.ps1)
# Background: fire.hlsl → "fire"
# Mouse: mouse/radial_glow.hlsl → "mouse_radialGlow"
function Get-ShaderKey($hlslFile) {
    $baseName = $hlslFile.BaseName
    $funcName = ($baseName -split '[_\-]' | ForEach-Object {
        $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower()
    }) -join ''
    $regKey = $funcName.Substring(0,1).ToLower() + $funcName.Substring(1)

    # Check if shader is in a subdirectory
    if ($hlslFile.DirectoryName -ne $shaderDir) {
        $subdir = Split-Path -Leaf $hlslFile.DirectoryName
        $regKey = $subdir + '_' + $regKey
    }
    return $regKey
}

# === Check staleness for each shader ===
$staleShaders = @()
$cachedCount = 0
$totalPS = $hlslFiles.Count
$totalVS = 1  # VSMain
$totalCS = 0  # Compute shaders (detected from .json metadata)

# Detect compute shaders from .json metadata
$computeShaders = @{}
foreach ($hlsl in $hlslFiles) {
    $jsonPath = [IO.Path]::ChangeExtension($hlsl.FullName, '.json')
    if (Test-Path $jsonPath) {
        try {
            $meta = Get-Content $jsonPath -Raw | ConvertFrom-Json
            if ($meta.PSObject.Properties['compute']) {
                $key = Get-ShaderKey $hlsl
                $computeShaders[$key] = $true
                $totalCS++
            }
        } catch { }  # Ignore malformed JSON
    }
}

$totalShaders = $totalPS + $totalVS + $totalCS

Write-Host "Scanning $totalShaders shaders ($totalPS PS + $totalCS CS + $totalVS VS)..."

# Common header timestamp — forces recompile when header changes
$commonHlslPath = Join-Path $shaderDir 'alt_tabby_common.hlsl'
$commonHlslTime = $null
if (Test-Path $commonHlslPath) {
    $commonHlslTime = (Get-Item $commonHlslPath).LastWriteTime
}

foreach ($hlsl in $hlslFiles) {
    $key = Get-ShaderKey $hlsl
    $binPath = Join-Path $outputDir "ps_$key.bin"

    if (!$force -and (Test-Path $binPath)) {
        $binTime = (Get-Item $binPath).LastWriteTime
        $hlslTime = $hlsl.LastWriteTime
        # Common header change forces recompile
        if ($commonHlslTime -and $commonHlslTime -gt $binTime) {
            # Fall through to add as stale
        } elseif ($binTime -gt $hlslTime) {
            $cachedCount++
            continue
        }
    }

    # Compute shaders use ps_5_0 (paired with cs_5_0); standard shaders use ps_4_0
    $isCompute = $computeShaders.ContainsKey($key)
    $psTarget = if ($isCompute) { "ps_5_0" } else { "ps_4_0" }

    $staleShaders += @{
        Key      = $key
        HlslPath = $hlsl.FullName
        BinPath  = $binPath
        Entry    = "PSMain"
        Target   = $psTarget
    }

    # Compute shaders also need CSMain compiled
    if ($isCompute) {
        $csBinPath = Join-Path $outputDir "cs_$key.bin"
        if (!$force -and (Test-Path $csBinPath)) {
            $csBinTime = (Get-Item $csBinPath).LastWriteTime
            if ($commonHlslTime -and $commonHlslTime -gt $csBinTime) {
                # Fall through — common header changed
            } elseif ($csBinTime -gt $hlsl.LastWriteTime) {
                $cachedCount++  # CS is cached (PS staleness already handled above)
            } else {
                # CS is stale — fall through
            }
        }
        # Only add CS entry if it wasn't cached
        $csIsCached = !$force -and (Test-Path $csBinPath) -and
            ((Get-Item $csBinPath).LastWriteTime -gt $hlsl.LastWriteTime) -and
            (!$commonHlslTime -or (Get-Item $csBinPath).LastWriteTime -gt $commonHlslTime)
        if ($csIsCached) {
            $cachedCount++
        } else {
            $staleShaders += @{
                Key      = $key
                HlslPath = $hlsl.FullName
                BinPath  = $csBinPath
                Entry    = "CSMain"
                Target   = "cs_5_0"
            }
        }
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

    # === Validate worker prerequisites ===
    if (!(Test-Path $ahk2base)) {
        Write-Host "ERROR: AutoHotkey v2 not found at: $ahk2base" -ForegroundColor Red
        exit 1
    }
    if (!(Test-Path $workerScript)) {
        Write-Host "ERROR: Worker script not found: $workerScript" -ForegroundColor Red
        exit 1
    }

    # === Partition shaders into N chunks for parallel compilation ===
    $workerCount = [Math]::Min([Math]::Max([int]([Environment]::ProcessorCount / 2), 1), 8)
    if ($staleShaders.Count -lt $workerCount) { $workerCount = $staleShaders.Count }
    Write-Host "  Compiling with $workerCount parallel worker(s)..."

    # Round-robin partition into chunks
    $chunks = @()
    for ($i = 0; $i -lt $workerCount; $i++) { $chunks += ,@() }
    for ($i = 0; $i -lt $staleShaders.Count; $i++) {
        $chunks[$i % $workerCount] += $staleShaders[$i]
    }

    # === Write manifests and spawn workers ===
    $workers = @()
    $guid = [Guid]::NewGuid().ToString('N').Substring(0,8)
    for ($i = 0; $i -lt $workerCount; $i++) {
        $manifestPath = Join-Path ([IO.Path]::GetTempPath()) "alttabby_shader_manifest_${guid}_${i}.txt"
        $manifestLines = @()
        foreach ($s in $chunks[$i]) {
            $manifestLines += "$($s.HlslPath)|$($s.BinPath)|$($s.Entry)|$($s.Target)"
        }
        [IO.File]::WriteAllLines($manifestPath, $manifestLines)

        $proc = Start-Process -FilePath $ahk2base `
            -ArgumentList "/ErrorStdOut `"$workerScript`" `"$manifestPath`"" `
            -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput "$manifestPath.out" `
            -RedirectStandardError "$manifestPath.err"

        $workers += @{
            Process      = $proc
            ManifestPath = $manifestPath
            ShaderCount  = $chunks[$i].Count
        }
    }

    # === Wait for all workers and collect results ===
    $totalFailures = 0
    foreach ($w in $workers) {
        $w.Process.WaitForExit()

        # Display worker output
        $outPath = "$($w.ManifestPath).out"
        if (Test-Path $outPath) {
            $workerOutput = Get-Content $outPath -Raw
            if ($workerOutput) {
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
            Remove-Item $outPath -Force -ErrorAction SilentlyContinue
        }
        $errPath = "$($w.ManifestPath).err"
        if (Test-Path $errPath) {
            $errContent = Get-Content $errPath -Raw
            if ($errContent) { Write-Host $errContent -ForegroundColor Red }
            Remove-Item $errPath -Force -ErrorAction SilentlyContinue
        }

        # Accumulate failures (exit code = number of failed shaders)
        if ($w.Process.ExitCode -ne 0) {
            $totalFailures += $w.Process.ExitCode
        }

        # Cleanup manifest
        Remove-Item $w.ManifestPath -Force -ErrorAction SilentlyContinue
    }

    # Cleanup VS temp HLSL
    if ($vsTempHlsl -and (Test-Path $vsTempHlsl)) {
        Remove-Item $vsTempHlsl -Force -ErrorAction SilentlyContinue
    }

    # Check for failures
    if ($totalFailures -ne 0) {
        Write-Host ""
        Write-Host "ERROR: $totalFailures shader(s) failed to compile." -ForegroundColor Red
        exit 1
    }
}

# === Clean stale .bin files ===
# Build set of expected .bin filenames
$expectedBins = @{}
$expectedBins["vs_VSMain.bin"] = $true
foreach ($hlsl in $hlslFiles) {
    $key = Get-ShaderKey $hlsl
    $expectedBins["ps_$key.bin"] = $true
    if ($computeShaders.ContainsKey($key)) {
        $expectedBins["cs_$key.bin"] = $true
    }
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
        $key = Get-ShaderKey $hlsl
        $binPath = Join-Path $outputDir "ps_$key.bin"
        if (!(Test-Path $binPath)) {
            Write-Host "  MISSING: ps_$key.bin" -ForegroundColor Red
        }
        if ($computeShaders.ContainsKey($key)) {
            $csBinPath = Join-Path $outputDir "cs_$key.bin"
            if (!(Test-Path $csBinPath)) {
                Write-Host "  MISSING: cs_$key.bin" -ForegroundColor Red
            }
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
