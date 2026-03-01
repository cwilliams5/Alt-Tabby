# shader_bundle.ps1 — Scans src/shaders/*.hlsl + *.json, generates:
#   src/lib/shader_bundle.ahk    — Metadata + Shader_RegisterAll() + SHADER_NAMES (no HLSL source)
#   src/lib/shader_resources.ahk — @Ahk2Exe-AddResource directives for textures + DXBC bytecode
#
# HLSL source is NO LONGER embedded in shader_bundle.ahk. Pre-compiled DXBC bytecode
# is shipped as embedded resources (compiled by tools/shader_compile.ps1).
#
# Usage: powershell -File tools/shader_bundle.ps1
#        powershell -File tools/shader_bundle.ps1 -Verbose

param(
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'

# Resolve paths relative to repo root (script lives in tools/)
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$shaderDir = Join-Path $repoRoot 'src\shaders'
$libDir = Join-Path $repoRoot 'src\lib'
$resImgDir = Join-Path $repoRoot 'resources\img\shaders'
$resDxbcDir = Join-Path $repoRoot 'resources\shaders'
$bundlePath = Join-Path $libDir 'shader_bundle.ahk'
$resourcesPath = Join-Path $libDir 'shader_resources.ahk'

# Ensure output dirs exist
if (!(Test-Path $resImgDir)) { New-Item -ItemType Directory -Path $resImgDir -Force | Out-Null }

# Discover shaders: each .hlsl must have a matching .json
$hlslFiles = Get-ChildItem -Path $shaderDir -Filter '*.hlsl' | Sort-Object Name
if ($hlslFiles.Count -eq 0) {
    Write-Host "No .hlsl files found in $shaderDir"
    exit 0
}

$shaders = @()
foreach ($hlsl in $hlslFiles) {
    $baseName = $hlsl.BaseName
    $jsonPath = Join-Path $shaderDir "$baseName.json"
    if (!(Test-Path $jsonPath)) {
        Write-Warning "Skipping $baseName.hlsl - no matching .json metadata"
        continue
    }
    $meta = Get-Content $jsonPath -Raw | ConvertFrom-Json

    # Sanitize name for AHK function: snake_case -> PascalCase
    $funcName = ($baseName -split '[_\-]' | ForEach-Object {
        $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower()
    }) -join ''

    # Registry key: camelCase version
    $regKey = $funcName.Substring(0,1).ToLower() + $funcName.Substring(1)

    # Extract metadata fields (PS 5.1 compatible — no inline if)
    $opacity = 1.0
    if ($meta.PSObject.Properties.Match('opacity').Count -gt 0) {
        $opacity = $meta.opacity
    }
    $iChannels = @()
    if ($meta.PSObject.Properties.Match('iChannels').Count -gt 0 -and $null -ne $meta.iChannels) {
        $iChannels = @($meta.iChannels)
    }

    # Time offset fields (optional per-shader overrides)
    $timeOffsetMin = $null
    if ($meta.PSObject.Properties.Match('timeOffsetMin').Count -gt 0) {
        $timeOffsetMin = $meta.timeOffsetMin
    }
    $timeOffsetMax = $null
    if ($meta.PSObject.Properties.Match('timeOffsetMax').Count -gt 0) {
        $timeOffsetMax = $meta.timeOffsetMax
    }
    $timeAccumulate = $null
    if ($meta.PSObject.Properties.Match('timeAccumulate').Count -gt 0) {
        $timeAccumulate = $meta.timeAccumulate
    }

    $shader = @{
        BaseName       = $baseName
        FuncName       = $funcName
        RegKey         = $regKey
        DisplayName    = $meta.name
        Opacity        = $opacity
        iChannels      = $iChannels
        TimeOffsetMin  = $timeOffsetMin
        TimeOffsetMax  = $timeOffsetMax
        TimeAccumulate = $timeAccumulate
    }
    $shaders += $shader

    if ($Verbose) {
        Write-Host "  Found: $baseName -> $funcName (display: $($meta.name))"
    }
}

if ($shaders.Count -eq 0) {
    Write-Host "No valid shader pairs found."
    exit 0
}

Write-Host "Bundling $($shaders.Count) shader(s)..."

# ==================== Copy texture PNGs ====================
$nextTexResId = 100  # Texture resources start at 100
$textureEntries = @()

foreach ($shader in $shaders) {
    foreach ($ch in $shader.iChannels) {
        $srcPng = Join-Path $shaderDir $ch.file
        if (!(Test-Path $srcPng)) {
            Write-Warning "iChannel texture not found: $($ch.file) for shader $($shader.BaseName)"
            continue
        }
        $dstPng = Join-Path $resImgDir $ch.file
        Copy-Item $srcPng $dstPng -Force

        $constName = "RES_ID_SHADER_$($shader.FuncName.ToUpper())_I$($ch.index)"
        $textureEntries += @{
            ConstName = $constName
            ResId     = $nextTexResId
            File      = $ch.file
            RelPath   = "..\resources\img\shaders\$($ch.file)"
        }
        $nextTexResId++

        if ($Verbose) {
            Write-Host "  Texture: $($ch.file) -> resId=$($textureEntries[-1].ResId)"
        }
    }
}

# ==================== Clean stale textures from resources/img/shaders ====================
$expectedFiles = @{}
foreach ($entry in $textureEntries) {
    $expectedFiles[$entry.File] = $true
}
$existingFiles = Get-ChildItem -Path $resImgDir -File -ErrorAction SilentlyContinue
foreach ($f in $existingFiles) {
    if (-not $expectedFiles.ContainsKey($f.Name)) {
        Remove-Item $f.FullName -Force
        if ($Verbose) {
            Write-Host "  Removed stale texture: $($f.Name)"
        }
    }
}

# ==================== Build DXBC resource entries ====================
# DXBC bytecode resources start at 1000 (clear separation from textures at 100+)
$nextDxbcResId = 1000
$dxbcEntries = @()

# Vertex shader first
$dxbcEntries += @{
    ConstName = "RES_ID_SHADER_VS"
    ResId     = $nextDxbcResId
    BinFile   = "vs_VSMain.bin"
    RelPath   = "..\resources\shaders\vs_VSMain.bin"
}
$nextDxbcResId++

# Pixel shaders (same order as $shaders)
foreach ($shader in $shaders) {
    $constName = "RES_ID_SHADER_PS_$($shader.FuncName.ToUpper())"
    $binFile = "ps_$($shader.RegKey).bin"
    $dxbcEntries += @{
        ConstName = $constName
        ResId     = $nextDxbcResId
        BinFile   = $binFile
        RelPath   = "..\resources\shaders\$binFile"
    }
    $nextDxbcResId++
}

# ==================== Generate shader_bundle.ahk ====================
$sb = New-Object System.Text.StringBuilder

[void]$sb.AppendLine('; AUTO-GENERATED by tools/shader_bundle.ps1 -- DO NOT EDIT')
[void]$sb.AppendLine('; Source: src/shaders/')
[void]$sb.AppendLine('; Regenerate: powershell -File tools/shader_bundle.ps1')
[void]$sb.AppendLine('; NOTE: HLSL source is NOT embedded. Pre-compiled DXBC bytecode is shipped as resources.')
[void]$sb.AppendLine('#Requires AutoHotkey v2.0')
[void]$sb.AppendLine('#Warn VarUnset, Off')
[void]$sb.AppendLine('')

# SHADER_NAMES global (0=None, 1+=alphabetical order)
$nameList = '"None"'
foreach ($shader in $shaders) {
    $nameList += ', "' + $shader.DisplayName + '"'
}
[void]$sb.AppendLine("global SHADER_NAMES := [$nameList]")

# SHADER_KEYS — parallel array of registry keys (index-aligned with SHADER_NAMES)
$keyList = '""'
foreach ($shader in $shaders) {
    $keyList += ', "' + $shader.RegKey + '"'
}
[void]$sb.AppendLine("global SHADER_KEYS := [$keyList]")
[void]$sb.AppendLine('')

# Shader_RegisterAll() — branches on A_IsCompiled
[void]$sb.AppendLine('Shader_RegisterAll() {')

# Build the global declaration for all DXBC resource IDs
$dxbcGlobals = ($dxbcEntries | ForEach-Object { $_.ConstName }) -join ', '
[void]$sb.AppendLine("    global $dxbcGlobals")
[void]$sb.AppendLine('')

[void]$sb.AppendLine('    if (A_IsCompiled) {')
foreach ($shader in $shaders) {
    $fn = $shader.FuncName
    $rk = $shader.RegKey
    $psConst = "RES_ID_SHADER_PS_$($shader.FuncName.ToUpper())"
    [void]$sb.AppendLine("        Shader_RegisterFromResource(`"$rk`", $psConst, _Shader_Meta_$fn())")
}
[void]$sb.AppendLine('    } else {')
foreach ($shader in $shaders) {
    $fn = $shader.FuncName
    $rk = $shader.RegKey
    $hlslFile = $shader.BaseName + '.hlsl'
    [void]$sb.AppendLine("        Shader_RegisterFromFile(`"$rk`", `"$hlslFile`", _Shader_Meta_$fn())")
}
[void]$sb.AppendLine('    }')
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('')

# Per-shader Meta functions (no HLSL functions — those are gone!)
foreach ($shader in $shaders) {
    $fn = $shader.FuncName

    [void]$sb.AppendLine("_Shader_Meta_$fn() {")

    # Build iChannels array string
    $chArray = '[]'
    if ($shader.iChannels.Count -gt 0) {
        $chEntries = @()
        foreach ($ch in $shader.iChannels) {
            $chEntries += '{index: ' + $ch.index + ', file: "' + $ch.file + '"}'
        }
        $chArray = '[' + ($chEntries -join ', ') + ']'
    }

    # Build optional time fields
    $timeFields = ''
    if ($null -ne $shader.TimeOffsetMin) {
        $timeFields += ", timeOffsetMin: $($shader.TimeOffsetMin)"
    }
    if ($null -ne $shader.TimeOffsetMax) {
        $timeFields += ", timeOffsetMax: $($shader.TimeOffsetMax)"
    }
    if ($null -ne $shader.TimeAccumulate) {
        $boolStr = 'false'
        if ($shader.TimeAccumulate) { $boolStr = 'true' }
        $timeFields += ", timeAccumulate: $boolStr"
    }

    [void]$sb.AppendLine("    return {opacity: $($shader.Opacity), iChannels: $chArray$timeFields}")
    [void]$sb.AppendLine('}')
    [void]$sb.AppendLine('')
}

# Write bundle file (UTF-8 without BOM)
[System.IO.File]::WriteAllText($bundlePath, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Host "  Generated: $bundlePath"

# ==================== Generate shader_resources.ahk ====================
$sr = New-Object System.Text.StringBuilder

[void]$sr.AppendLine('; AUTO-GENERATED by tools/shader_bundle.ps1 -- DO NOT EDIT')
[void]$sr.AppendLine('; Regenerate: powershell -File tools/shader_bundle.ps1')
[void]$sr.AppendLine('#Requires AutoHotkey v2.0')
[void]$sr.AppendLine('#Warn VarUnset, Off')
[void]$sr.AppendLine('')

# --- Texture resource directives (IDs 100-199) ---
if ($textureEntries.Count -gt 0) {
    [void]$sr.AppendLine('; Texture resources (IDs 100+)')
    foreach ($entry in $textureEntries) {
        [void]$sr.AppendLine(";@Ahk2Exe-AddResource $($entry.RelPath), $($entry.ResId)")
    }
    [void]$sr.AppendLine('')
}

# --- DXBC bytecode resource directives (IDs 1000+) ---
[void]$sr.AppendLine('; DXBC bytecode resources (IDs 1000+)')
foreach ($entry in $dxbcEntries) {
    [void]$sr.AppendLine(";@Ahk2Exe-AddResource $($entry.RelPath), $($entry.ResId)")
}
[void]$sr.AppendLine('')

# --- Texture resource ID constants ---
if ($textureEntries.Count -gt 0) {
    foreach ($entry in $textureEntries) {
        [void]$sr.AppendLine("global $($entry.ConstName) := $($entry.ResId)")
    }
    [void]$sr.AppendLine('')
}

# --- DXBC resource ID constants ---
foreach ($entry in $dxbcEntries) {
    [void]$sr.AppendLine("global $($entry.ConstName) := $($entry.ResId)")
}
[void]$sr.AppendLine('')

# Shader_ExtractTextures() function (unchanged — textures still need extraction)
[void]$sr.AppendLine('Shader_ExtractTextures() {')
if ($textureEntries.Count -gt 0) {
    $globals = ($textureEntries | ForEach-Object { $_.ConstName }) -join ', '
    [void]$sr.AppendLine("    global $globals")
    [void]$sr.AppendLine('    if (!A_IsCompiled)')
    [void]$sr.AppendLine('        return  ; dev mode loads from src/shaders/ directly')
    [void]$sr.AppendLine('    DirCreate(A_Temp "\shaders")')
    foreach ($entry in $textureEntries) {
        $cn = $entry.ConstName
        $fl = $entry.File
        [void]$sr.AppendLine("    ResourceExtractToTemp($cn, `"$fl`", A_Temp `"\shaders`")")
    }
} else {
    [void]$sr.AppendLine('    ; No textures to extract for current shaders')
}
[void]$sr.AppendLine('}')
[void]$sr.AppendLine('')

# Shader_GetTexturePath(fileName) helper
[void]$sr.AppendLine('; Get runtime path to a shader texture file.')
[void]$sr.AppendLine('; Compiled: extracted to %TEMP%\shaders\. Dev: loaded from src\shaders\ directly.')
[void]$sr.AppendLine('Shader_GetTexturePath(fileName) {')
[void]$sr.AppendLine('    if (A_IsCompiled)')
[void]$sr.AppendLine('        return A_Temp "\shaders\" fileName')
[void]$sr.AppendLine('    ; Dev mode: walk up from A_ScriptDir to find src/shaders/')
[void]$sr.AppendLine('    return A_ScriptDir "\shaders\" fileName')
[void]$sr.AppendLine('}')

[System.IO.File]::WriteAllText($resourcesPath, $sr.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Host "  Generated: $resourcesPath"

Write-Host "Done. $($shaders.Count) shader(s) bundled, $($textureEntries.Count) texture(s) + $($dxbcEntries.Count) DXBC bytecode registered."
