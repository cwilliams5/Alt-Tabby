# query_shader.ps1 - Shader metadata query
#
# Extracts shader metadata from the auto-generated shader_bundle.ahk without
# loading the full 1100+ line file into context.
#
# Usage:
#   powershell -File tools/query_shader.ps1                  (list all shaders with summary)
#   powershell -File tools/query_shader.ps1 fire              (fuzzy search by name/key)
#   powershell -File tools/query_shader.ps1 -Category mouse   (filter: background, mouse, selection)
#   powershell -File tools/query_shader.ps1 -Compute           (list only compute-enabled shaders)
#   powershell -File tools/query_shader.ps1 -Textures          (list only shaders with iChannel textures)

param(
    [Parameter(Position=0)]
    [string]$Query,
    [string]$Category,
    [switch]$Compute,
    [switch]$Textures
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$projectRoot = Split-Path $PSScriptRoot -Parent
$bundleFile = Join-Path $projectRoot "src\gui\shader_bundle.ahk"
$resourceFile = Join-Path $projectRoot "src\gui\shader_resources.ahk"

if (-not (Test-Path $bundleFile)) {
    Write-Host "  ERROR: Cannot find $bundleFile" -ForegroundColor Red
    exit 1
}

# === Parse name/key arrays ===
$bundleText = [System.IO.File]::ReadAllText($bundleFile)

function Parse-ArrayLine {
    param([string]$Text, [string]$VarName)
    if ($Text -match "global $VarName\s*:=\s*\[(.+)\]") {
        $raw = $Matches[1]
        $items = [System.Collections.ArrayList]::new()
        foreach ($m in [regex]::Matches($raw, '"([^"]*)"')) {
            [void]$items.Add($m.Groups[1].Value)
        }
        return ,$items
    }
    return ,@()
}

$bgNames = Parse-ArrayLine $bundleText "SHADER_NAMES"
$bgKeys = Parse-ArrayLine $bundleText "SHADER_KEYS"
$mouseNames = Parse-ArrayLine $bundleText "MOUSE_SHADER_NAMES"
$mouseKeys = Parse-ArrayLine $bundleText "MOUSE_SHADER_KEYS"
$selNames = Parse-ArrayLine $bundleText "SELECTION_SHADER_NAMES"
$selKeys = Parse-ArrayLine $bundleText "SELECTION_SHADER_KEYS"

# === Parse meta functions for iChannel and compute info ===
# Match meta functions — use greedy brace matching for nested objects (iChannels)
$metaRx = [regex]::new('_Shader_Meta_(\w+)\(\)\s*\{\s*return\s*(\{.+?\})\s*\}', 'Singleline')
$metaMap = @{}
foreach ($m in $metaRx.Matches($bundleText)) {
    $funcName = $m.Groups[1].Value
    $body = $m.Groups[2].Value
    $hasCompute = $body.Contains('compute:')
    $channelCount = ([regex]::Matches($body, 'index:\s*\d+')).Count
    $metaMap[$funcName] = @{ Compute = $hasCompute; Channels = $channelCount; Raw = $body.Trim() }
}

# === Parse registration lines to map key → registration type ===
$registerRx = [regex]::new('case\s+"(\w+)":\s+Shader_(RegisterComputeFromResource|RegisterFromResource|RegisterComputeFromFile|RegisterFromFile)\("([^"]+)",[^,]+,\s*_Shader_Meta_(\w+)\(\)')
$regMap = @{}
foreach ($m in $registerRx.Matches($bundleText)) {
    $key = $m.Groups[1].Value
    $regType = $m.Groups[2].Value
    $metaFunc = $m.Groups[4].Value
    $regMap[$key] = @{ MetaFunc = $metaFunc; RegType = $regType }
}

# === Parse texture resource IDs from shader_resources.ahk ===
$textureCount = 0
if (Test-Path $resourceFile) {
    $resText = [System.IO.File]::ReadAllText($resourceFile)
    $textureCount = ([regex]::Matches($resText, 'Ahk2Exe-AddResource .+shaders.+\.(png|jpg)')).Count
}

# === Build unified shader list ===
$shaders = [System.Collections.ArrayList]::new()

function Add-Shaders {
    param($Names, $Keys, [string]$Cat)
    for ($i = 0; $i -lt $Names.Count; $i++) {
        $name = $Names[$i]
        $key = $Keys[$i]
        if (-not $key) { continue }  # Skip "None" entries
        $reg = $regMap[$key]
        $meta = if ($reg) { $metaMap[$reg.MetaFunc] } else { $null }
        $hasCompute = if ($meta) { $meta.Compute } else { $false }
        $channels = if ($meta) { $meta.Channels } else { 0 }
        [void]$shaders.Add(@{
            Name = $name; Key = $key; Category = $Cat
            Compute = $hasCompute; Channels = $channels
            MetaFunc = if ($reg) { $reg.MetaFunc } else { "" }
        })
    }
}

Add-Shaders $bgNames $bgKeys "background"
Add-Shaders $mouseNames $mouseKeys "mouse"
Add-Shaders $selNames $selKeys "selection"

# === Apply filters ===
$filtered = $shaders

if ($Category) {
    $catLower = $Category.ToLower()
    $filtered = @($filtered | Where-Object { $_.Category -eq $catLower })
}
if ($Compute) {
    $filtered = @($filtered | Where-Object { $_.Compute })
}
if ($Textures) {
    $filtered = @($filtered | Where-Object { $_.Channels -gt 0 })
}
if ($Query) {
    $qLower = $Query.ToLower()
    $filtered = @($filtered | Where-Object {
        $_.Name.ToLower().Contains($qLower) -or $_.Key.ToLower().Contains($qLower)
    })
}

# === Output ===
if ($filtered.Count -eq 0 -and $Query) {
    Write-Host "`n  No shaders matching '$Query'" -ForegroundColor Red
    Write-Host "  Total: $($shaders.Count) shaders ($($bgNames.Count - 1) background, $($mouseNames.Count - 1) mouse, $($selNames.Count - 1) selection)"
    Write-Host ""; exit 1
}

if ($filtered.Count -eq 1 -or ($Query -and $filtered.Count -le 3)) {
    # Detail mode
    foreach ($s in $filtered) {
        $meta = if ($s.MetaFunc) { $metaMap[$s.MetaFunc] } else { $null }
        Write-Host ""
        Write-Host "  $($s.Name)" -ForegroundColor White
        Write-Host "    key:      $($s.Key)" -ForegroundColor Cyan
        Write-Host "    category: $($s.Category)" -ForegroundColor Cyan
        Write-Host "    compute:  $(if ($s.Compute) { 'yes (compute + pixel shader)' } else { 'no (pixel shader only)' })" -ForegroundColor $(if ($s.Compute) { "Green" } else { "DarkGray" })
        Write-Host "    textures: $(if ($s.Channels -gt 0) { "$($s.Channels) iChannel(s)" } else { 'none' })" -ForegroundColor $(if ($s.Channels -gt 0) { "Green" } else { "DarkGray" })
        if ($meta) {
            Write-Host "    meta:     $($meta.Raw)" -ForegroundColor DarkGray
        }
    }
} else {
    # Table mode
    $title = "Shaders"
    if ($Category) { $title = "$Category shaders" }
    elseif ($Compute) { $title = "Compute-enabled shaders" }
    elseif ($Textures) { $title = "Shaders with textures" }
    elseif ($Query) { $title = "Shaders matching '$Query'" }

    Write-Host ""
    Write-Host "  $title ($($filtered.Count)):" -ForegroundColor White
    Write-Host ""

    $maxNameLen = ($filtered | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    $maxNameLen = [Math]::Min($maxNameLen, 45)

    foreach ($s in ($filtered | Sort-Object { $_.Category }, { $_.Name })) {
        $nameStr = $s.Name.PadRight($maxNameLen + 2)
        $catStr = $s.Category.PadRight(12)
        $flags = ""
        if ($s.Compute) { $flags += "CS " }
        if ($s.Channels -gt 0) { $flags += "T$($s.Channels) " }
        $color = switch ($s.Category) { "background" { "Cyan" } "mouse" { "Green" } "selection" { "Yellow" } }
        Write-Host "    $nameStr $catStr $flags" -ForegroundColor $color
    }
}

Write-Host ""
$totalBg = $bgNames.Count - 1
$totalMouse = $mouseNames.Count - 1
$totalSel = $selNames.Count - 1
$totalCompute = @($shaders | Where-Object { $_.Compute }).Count
$totalTextured = @($shaders | Where-Object { $_.Channels -gt 0 }).Count
Write-Host "  Total: $($shaders.Count) shaders ($totalBg bg, $totalMouse mouse, $totalSel selection) | $totalCompute compute | $totalTextured textured | $textureCount texture resources" -ForegroundColor DarkGray
$elapsed = $sw.ElapsedMilliseconds
Write-Host "  Completed in ${elapsed}ms" -ForegroundColor DarkGray
