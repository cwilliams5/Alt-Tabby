# shader_bundle.ps1 — Scans src/shaders/**/*.hlsl + *.json, generates:
#   src/gui/shader_bundle.ahk    — Metadata + Register functions + SHADER/MOUSE/SELECTION arrays
#   src/gui/shader_resources.ahk — @Ahk2Exe-AddResource directives for textures + DXBC bytecode
#
# HLSL source is NOT embedded. Pre-compiled DXBC bytecode is shipped as resources.
# Shaders in subdirectories (mouse/, selection/) get category-specific arrays.
#
# Usage: powershell -File tools/shader_bundle.ps1
#        powershell -File tools/shader_bundle.ps1 -Verbose

param(
    [switch]$Verbose,
    [switch]$force
)

$ErrorActionPreference = 'Stop'

# Resolve paths relative to repo root (script lives in tools/)
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$shaderDir = Join-Path $repoRoot 'src\shaders'
$guiDir = Join-Path $repoRoot 'src\gui'
$resImgDir = Join-Path $repoRoot 'resources\img\shaders'
$resDxbcDir = Join-Path $repoRoot 'resources\shaders'
$bundlePath = Join-Path $guiDir 'shader_bundle.ahk'
$resourcesPath = Join-Path $guiDir 'shader_resources.ahk'

# Ensure output dirs exist
if (!(Test-Path $resImgDir)) { New-Item -ItemType Directory -Path $resImgDir -Force | Out-Null }

# Discover shaders recursively: each .hlsl must have a matching .json
$hlslFiles = @(Get-ChildItem -Path $shaderDir -Filter '*.hlsl' -Recurse |
    Where-Object { $_.Name -ne 'alt_tabby_common.hlsl' } | Sort-Object FullName)
if ($hlslFiles.Count -eq 0) {
    Write-Host "No .hlsl files found in $shaderDir"
    exit 0
}

# === Staleness check: skip if outputs are newer than all inputs ===
if (-not $force -and (Test-Path $bundlePath) -and (Test-Path $resourcesPath)) {
    $outTime = @((Get-Item $bundlePath).LastWriteTime, (Get-Item $resourcesPath).LastWriteTime) |
        Sort-Object | Select-Object -First 1  # oldest output
    $jsonFiles = @(Get-ChildItem -Path $shaderDir -Filter '*.json' -Recurse -ErrorAction SilentlyContinue)
    $scriptTime = (Get-Item $PSCommandPath).LastWriteTime
    $commonHlsl = Get-Item (Join-Path $shaderDir 'alt_tabby_common.hlsl') -ErrorAction SilentlyContinue
    $allInputs = @($hlslFiles) + @($jsonFiles) + @(Get-Item $PSCommandPath)
    if ($commonHlsl) { $allInputs += @($commonHlsl) }
    $newestInput = $allInputs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($outTime -gt $newestInput.LastWriteTime) {
        Write-Host "Shader bundle up to date ($($hlslFiles.Count) shaders)."
        exit 0
    }
}

# === Categorize shaders by subdirectory ===
# Root = background, mouse/ = mouse, selection/ = selection
function Get-ShaderCategory($hlslFile) {
    $rel = $hlslFile.DirectoryName
    if ($rel -eq $shaderDir) { return 'background' }
    $subdir = Split-Path -Leaf $rel
    switch ($subdir) {
        'mouse'     { return 'mouse' }
        'selection' { return 'selection' }
        default     { return 'background' }  # Unknown subdirs treated as background
    }
}

# Build shader key from filename + optional subdir prefix
# Background: fire.hlsl → regKey "fire", funcName "Fire"
# Mouse: mouse/radial_glow.hlsl → regKey "mouse_radialGlow", funcName "MouseRadialGlow"
function Get-ShaderNaming($baseName, $category) {
    $funcName = ($baseName -split '[_\-]' | ForEach-Object {
        $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower()
    }) -join ''
    $regKey = $funcName.Substring(0,1).ToLower() + $funcName.Substring(1)

    if ($category -ne 'background') {
        $prefix = $category.Substring(0,1).ToUpper() + $category.Substring(1)
        $funcName = $prefix + $funcName
        $regKey = $category + '_' + $regKey
    }

    return @{ FuncName = $funcName; RegKey = $regKey }
}

# Build display name with category prefix
function Get-DisplayName($metaName, $category) {
    switch ($category) {
        'mouse'     { return "[Mouse] $metaName" }
        'selection' { return "[Selection] $metaName" }
        default     { return $metaName }
    }
}

$allShaders = @()
foreach ($hlsl in $hlslFiles) {
    $baseName = $hlsl.BaseName
    $jsonPath = Join-Path $hlsl.DirectoryName "$baseName.json"
    if (!(Test-Path $jsonPath)) {
        Write-Warning "Skipping $($hlsl.FullName) - no matching .json metadata"
        continue
    }
    $meta = Get-Content $jsonPath -Raw | ConvertFrom-Json
    $category = Get-ShaderCategory $hlsl
    $naming = Get-ShaderNaming $baseName $category

    # Relative HLSL path from src/shaders/ (for dev mode RegisterFromFile)
    $relHlslPath = $hlsl.FullName.Substring($shaderDir.Length + 1).Replace('\', '/')
    # For Windows path in AHK, use backslashes
    $relHlslAhk = $relHlslPath.Replace('/', '\')

    # Extract metadata fields (PS 5.1 compatible)
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

    # Compute shader metadata (optional)
    $compute = $null
    if ($meta.PSObject.Properties.Match('compute').Count -gt 0 -and $null -ne $meta.compute) {
        $baseParticles = 0
        if ($meta.compute.PSObject.Properties.Match('baseParticles').Count -gt 0) {
            $baseParticles = $meta.compute.baseParticles
        }
        $compute = @{
            MaxParticles   = $meta.compute.maxParticles
            ParticleStride = $meta.compute.particleStride
            BaseParticles  = $baseParticles
        }
    }

    $shader = @{
        BaseName       = $baseName
        FuncName       = $naming.FuncName
        RegKey         = $naming.RegKey
        DisplayName    = Get-DisplayName $meta.name $category
        ShortName      = $meta.name  # Without category prefix
        Category       = $category
        RelHlsl        = $relHlslAhk
        Opacity        = $opacity
        iChannels      = $iChannels
        TimeOffsetMin  = $timeOffsetMin
        TimeOffsetMax  = $timeOffsetMax
        TimeAccumulate = $timeAccumulate
        Compute        = $compute
    }
    $allShaders += $shader

    if ($Verbose) {
        Write-Host "  Found: [$category] $baseName -> $($naming.RegKey) (display: $($shader.DisplayName))"
    }
}

if ($allShaders.Count -eq 0) {
    Write-Host "No valid shader pairs found."
    exit 0
}

# Split by category
$bgShaders = @($allShaders | Where-Object { $_.Category -eq 'background' })
$mouseShaders = @($allShaders | Where-Object { $_.Category -eq 'mouse' })
$selShaders = @($allShaders | Where-Object { $_.Category -eq 'selection' })

Write-Host "Bundling $($allShaders.Count) shader(s): $($bgShaders.Count) bg, $($mouseShaders.Count) mouse, $($selShaders.Count) selection..."

# ==================== Copy texture PNGs ====================
$nextTexResId = 100  # Texture resources start at 100
$textureEntries = @()

foreach ($shader in $allShaders) {
    foreach ($ch in $shader.iChannels) {
        # Textures live alongside their HLSL file
        $srcDir = $shaderDir
        if ($shader.Category -ne 'background') {
            $srcDir = Join-Path $shaderDir $shader.Category
        }
        $srcPng = Join-Path $srcDir $ch.file
        if (!(Test-Path $srcPng)) {
            # Also check root shader dir
            $srcPng = Join-Path $shaderDir $ch.file
        }
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

# Pixel shaders (all categories, sorted by key for stable ordering)
foreach ($shader in $allShaders) {
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

# Compute shaders (IDs 2000+)
$nextCsDxbcResId = 2000
foreach ($shader in $allShaders) {
    if ($null -eq $shader.Compute) { continue }
    $constName = "RES_ID_SHADER_CS_$($shader.FuncName.ToUpper())"
    $binFile = "cs_$($shader.RegKey).bin"
    $dxbcEntries += @{
        ConstName = $constName
        ResId     = $nextCsDxbcResId
        BinFile   = $binFile
        RelPath   = "..\resources\shaders\$binFile"
    }
    $nextCsDxbcResId++
}

# ==================== Generate shader_bundle.ahk ====================
$sb = New-Object System.Text.StringBuilder

[void]$sb.AppendLine('; AUTO-GENERATED by tools/shader_bundle.ps1 -- DO NOT EDIT')
[void]$sb.AppendLine('; Source: src/shaders/ (including mouse/, selection/ subdirs)')
[void]$sb.AppendLine('; Regenerate: powershell -File tools/shader_bundle.ps1')
[void]$sb.AppendLine('; NOTE: HLSL source is NOT embedded. Pre-compiled DXBC bytecode is shipped as resources.')
[void]$sb.AppendLine('#Requires AutoHotkey v2.0')
[void]$sb.AppendLine('#Warn VarUnset, Off')
[void]$sb.AppendLine('')

# === Helper: build name/key arrays for a shader list ===
function Write-ArrayPair($sb, $prefix, $shaders) {
    # NAMES array (0=None, 1+=order)
    $nameList = '"None"'
    foreach ($s in $shaders) {
        $nameList += ', "' + $s.ShortName + '"'
    }
    [void]$sb.AppendLine("global ${prefix}_NAMES := [$nameList]")

    # KEYS array (parallel, index-aligned)
    $keyList = '""'
    foreach ($s in $shaders) {
        $keyList += ', "' + $s.RegKey + '"'
    }
    [void]$sb.AppendLine("global ${prefix}_KEYS := [$keyList]")
    [void]$sb.AppendLine('')
}

# Background shader arrays
Write-ArrayPair $sb 'SHADER' $bgShaders

# Mouse shader arrays
Write-ArrayPair $sb 'MOUSE_SHADER' $mouseShaders

# Selection shader arrays
Write-ArrayPair $sb 'SELECTION_SHADER' $selShaders

# Build global declaration for all DXBC resource IDs
$dxbcGlobals = ($dxbcEntries | ForEach-Object { $_.ConstName }) -join ', '

# === Helper: emit register function body for a shader list ===
function Write-RegisterBody($sb, $shaders, $dxbcGlobals, $indent) {
    [void]$sb.AppendLine("${indent}if (A_IsCompiled) {")
    foreach ($s in $shaders) {
        $fn = $s.FuncName
        $rk = $s.RegKey
        $psConst = "RES_ID_SHADER_PS_$($s.FuncName.ToUpper())"
        if ($null -ne $s.Compute) {
            $csConst = "RES_ID_SHADER_CS_$($s.FuncName.ToUpper())"
            [void]$sb.AppendLine("$indent    Shader_RegisterComputeFromResource(`"$rk`", $csConst, $psConst, _Shader_Meta_$fn())")
        } else {
            [void]$sb.AppendLine("$indent    Shader_RegisterFromResource(`"$rk`", $psConst, _Shader_Meta_$fn())")
        }
    }
    [void]$sb.AppendLine("${indent}} else {")
    foreach ($s in $shaders) {
        $fn = $s.FuncName
        $rk = $s.RegKey
        $hlslFile = $s.RelHlsl
        if ($null -ne $s.Compute) {
            [void]$sb.AppendLine("$indent    Shader_RegisterComputeFromFile(`"$rk`", `"$hlslFile`", _Shader_Meta_$fn())")
        } else {
            [void]$sb.AppendLine("$indent    Shader_RegisterFromFile(`"$rk`", `"$hlslFile`", _Shader_Meta_$fn())")
        }
    }
    [void]$sb.AppendLine("${indent}}")
}

# Shader_RegisterAll() — background shaders only (backward compat)
[void]$sb.AppendLine('Shader_RegisterAll() {')
[void]$sb.AppendLine("    global $dxbcGlobals")
[void]$sb.AppendLine('')
Write-RegisterBody $sb $bgShaders $dxbcGlobals '    '
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('')

# Shader_RegisterAllMouse()
[void]$sb.AppendLine('Shader_RegisterAllMouse() {')
[void]$sb.AppendLine("    global $dxbcGlobals")
[void]$sb.AppendLine('')
if ($mouseShaders.Count -gt 0) {
    Write-RegisterBody $sb $mouseShaders $dxbcGlobals '    '
} else {
    [void]$sb.AppendLine('    ; No mouse shaders defined')
}
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('')

# Shader_RegisterAllSelection()
[void]$sb.AppendLine('Shader_RegisterAllSelection() {')
[void]$sb.AppendLine("    global $dxbcGlobals")
[void]$sb.AppendLine('')
if ($selShaders.Count -gt 0) {
    Write-RegisterBody $sb $selShaders $dxbcGlobals '    '
} else {
    [void]$sb.AppendLine('    ; No selection shaders defined')
}
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('')

# Shader_RegisterByKey(key) — unified across all categories
[void]$sb.AppendLine('; Register a single shader by registry key. Used for selective loading at boot.')
[void]$sb.AppendLine('Shader_RegisterByKey(key) {')
[void]$sb.AppendLine("    global $dxbcGlobals")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('    if (A_IsCompiled) {')
[void]$sb.AppendLine('        switch key {')
foreach ($shader in $allShaders) {
    $fn = $shader.FuncName
    $rk = $shader.RegKey
    $psConst = "RES_ID_SHADER_PS_$($shader.FuncName.ToUpper())"
    if ($null -ne $shader.Compute) {
        $csConst = "RES_ID_SHADER_CS_$($shader.FuncName.ToUpper())"
        [void]$sb.AppendLine("            case `"$rk`": Shader_RegisterComputeFromResource(`"$rk`", $csConst, $psConst, _Shader_Meta_$fn())")
    } else {
        [void]$sb.AppendLine("            case `"$rk`": Shader_RegisterFromResource(`"$rk`", $psConst, _Shader_Meta_$fn())")
    }
}
[void]$sb.AppendLine('        }')
[void]$sb.AppendLine('    } else {')
[void]$sb.AppendLine('        switch key {')
foreach ($shader in $allShaders) {
    $fn = $shader.FuncName
    $rk = $shader.RegKey
    $hlslFile = $shader.RelHlsl
    if ($null -ne $shader.Compute) {
        [void]$sb.AppendLine("            case `"$rk`": Shader_RegisterComputeFromFile(`"$rk`", `"$hlslFile`", _Shader_Meta_$fn())")
    } else {
        [void]$sb.AppendLine("            case `"$rk`": Shader_RegisterFromFile(`"$rk`", `"$hlslFile`", _Shader_Meta_$fn())")
    }
}
[void]$sb.AppendLine('        }')
[void]$sb.AppendLine('    }')
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('')

# Shader_RegisterAllRemaining() — background shaders only (backward compat)
[void]$sb.AppendLine('; Register all background shaders that are not yet registered. Used for lazy-loading on first cycle.')
[void]$sb.AppendLine('Shader_RegisterAllRemaining() {')
[void]$sb.AppendLine("    global gShader_Registry, $dxbcGlobals")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('    if (A_IsCompiled) {')
foreach ($shader in $bgShaders) {
    $fn = $shader.FuncName
    $rk = $shader.RegKey
    $psConst = "RES_ID_SHADER_PS_$($shader.FuncName.ToUpper())"
    [void]$sb.AppendLine("        if (!gShader_Registry.Has(`"$rk`"))")
    [void]$sb.AppendLine("            Shader_RegisterFromResource(`"$rk`", $psConst, _Shader_Meta_$fn())")
}
[void]$sb.AppendLine('    } else {')
foreach ($shader in $bgShaders) {
    $fn = $shader.FuncName
    $rk = $shader.RegKey
    $hlslFile = $shader.RelHlsl
    [void]$sb.AppendLine("        if (!gShader_Registry.Has(`"$rk`"))")
    [void]$sb.AppendLine("            Shader_RegisterFromFile(`"$rk`", `"$hlslFile`", _Shader_Meta_$fn())")
}
[void]$sb.AppendLine('    }')
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('')

# Shader_RegisterAllRemainingMouse()
[void]$sb.AppendLine('; Register all mouse shaders that are not yet registered.')
[void]$sb.AppendLine('Shader_RegisterAllRemainingMouse() {')
[void]$sb.AppendLine("    global gShader_Registry, $dxbcGlobals")
[void]$sb.AppendLine('')
if ($mouseShaders.Count -gt 0) {
    [void]$sb.AppendLine('    if (A_IsCompiled) {')
    foreach ($shader in $mouseShaders) {
        $fn = $shader.FuncName
        $rk = $shader.RegKey
        $psConst = "RES_ID_SHADER_PS_$($shader.FuncName.ToUpper())"
        [void]$sb.AppendLine("        if (!gShader_Registry.Has(`"$rk`")) {")
        if ($null -ne $shader.Compute) {
            $csConst = "RES_ID_SHADER_CS_$($shader.FuncName.ToUpper())"
            [void]$sb.AppendLine("            Shader_RegisterComputeFromResource(`"$rk`", $csConst, $psConst, _Shader_Meta_$fn())")
        } else {
            [void]$sb.AppendLine("            Shader_RegisterFromResource(`"$rk`", $psConst, _Shader_Meta_$fn())")
        }
        [void]$sb.AppendLine("        }")
    }
    [void]$sb.AppendLine('    } else {')
    foreach ($shader in $mouseShaders) {
        $fn = $shader.FuncName
        $rk = $shader.RegKey
        $hlslFile = $shader.RelHlsl
        [void]$sb.AppendLine("        if (!gShader_Registry.Has(`"$rk`")) {")
        if ($null -ne $shader.Compute) {
            [void]$sb.AppendLine("            Shader_RegisterComputeFromFile(`"$rk`", `"$hlslFile`", _Shader_Meta_$fn())")
        } else {
            [void]$sb.AppendLine("            Shader_RegisterFromFile(`"$rk`", `"$hlslFile`", _Shader_Meta_$fn())")
        }
        [void]$sb.AppendLine("        }")
    }
    [void]$sb.AppendLine('    }')
}
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('')

# Shader_RegisterAllRemainingSelection()
[void]$sb.AppendLine('; Register all selection shaders that are not yet registered.')
[void]$sb.AppendLine('Shader_RegisterAllRemainingSelection() {')
[void]$sb.AppendLine("    global gShader_Registry, $dxbcGlobals")
[void]$sb.AppendLine('')
if ($selShaders.Count -gt 0) {
    [void]$sb.AppendLine('    if (A_IsCompiled) {')
    foreach ($shader in $selShaders) {
        $fn = $shader.FuncName
        $rk = $shader.RegKey
        $psConst = "RES_ID_SHADER_PS_$($shader.FuncName.ToUpper())"
        [void]$sb.AppendLine("        if (!gShader_Registry.Has(`"$rk`"))")
        [void]$sb.AppendLine("            Shader_RegisterFromResource(`"$rk`", $psConst, _Shader_Meta_$fn())")
    }
    [void]$sb.AppendLine('    } else {')
    foreach ($shader in $selShaders) {
        $fn = $shader.FuncName
        $rk = $shader.RegKey
        $hlslFile = $shader.RelHlsl
        [void]$sb.AppendLine("        if (!gShader_Registry.Has(`"$rk`"))")
        [void]$sb.AppendLine("            Shader_RegisterFromFile(`"$rk`", `"$hlslFile`", _Shader_Meta_$fn())")
    }
    [void]$sb.AppendLine('    }')
}
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('')

# Per-shader Meta functions (all categories)
foreach ($shader in $allShaders) {
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

    # Build optional compute field
    $computeField = ''
    if ($null -ne $shader.Compute) {
        $computeField = ", compute: {maxParticles: $($shader.Compute.MaxParticles), particleStride: $($shader.Compute.ParticleStride), baseParticles: $($shader.Compute.BaseParticles)}"
    }

    [void]$sb.AppendLine("    return {opacity: $($shader.Opacity), iChannels: $chArray$timeFields$computeField}")
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

# Shader_ExtractTextures() function
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

Write-Host "Done. $($allShaders.Count) shader(s) bundled ($($bgShaders.Count) bg, $($mouseShaders.Count) mouse, $($selShaders.Count) sel), $($textureEntries.Count) texture(s) + $($dxbcEntries.Count) DXBC registered."
exit 0
