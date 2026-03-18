# query_config.ps1 - Config registry search
#
# Searches config_registry.ahk for settings matching a keyword.
# Returns semantic answers: section, key, type, default, description.
#
# Usage:
#   powershell -File tools/query_config.ps1                       (show section/group index)
#   powershell -File tools/query_config.ps1 theme                 (fuzzy search for "theme")
#   powershell -File tools/query_config.ps1 -Section GUI          (list all settings in a section)
#   powershell -File tools/query_config.ps1 -Usage GUI_RowHeight  (find all consumers of cfg.X)
#   powershell -File tools/query_config.ps1 -Format hex           (filter: all color/hex settings)
#   powershell -File tools/query_config.ps1 -Type int             (filter: all settings of type int/bool/string)
#   powershell -File tools/query_config.ps1 -HasBounds            (filter: all settings with min/max constraints)

param(
    [Parameter(Position=0)]
    [string]$Search,
    [string]$Section,
    [string]$Usage,
    [string]$Format,
    [string]$Type,
    [switch]$HasBounds
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\_query_helpers.ps1"

$projectRoot = (Resolve-Path "$PSScriptRoot\..").Path
$registryPath = (Resolve-Path "$projectRoot\src\shared\config_registry.ahk").Path
$rawLines = [System.IO.File]::ReadAllLines($registryPath)

# === Parse config registry entries ===
$sections = [System.Collections.ArrayList]::new()
$subsections = [System.Collections.ArrayList]::new()
$settings = [System.Collections.ArrayList]::new()

$entryText = ""
$braceDepth = 0

foreach ($rawLine in $rawLines) {
    $trimmed = $rawLine.Trim()
    if ($braceDepth -eq 0 -and $trimmed -match '^\s*;') { continue }

    $wasInBraces = $braceDepth -gt 0
    foreach ($c in $trimmed.ToCharArray()) {
        if ($c -eq '{') {
            if ($braceDepth -eq 0) { $entryText = "" }
            $braceDepth++
            $wasInBraces = $true
        } elseif ($c -eq '}') {
            $braceDepth--
        }
    }

    if ($wasInBraces) {
        $entryText += " " + $trimmed
    }

    if ($braceDepth -le 0 -and $entryText) {
        $braceDepth = 0
        $e = $entryText

        if ($e -match 'type:\s*"section"') {
            $eName = if ($e -match 'name:\s*"([^"]*)"') { $Matches[1] } else { "" }
            $eDesc = if ($e -match 'desc:\s*"([^"]*)"') { $Matches[1] } else { "" }
            [void]$sections.Add(@{ Name = $eName; Desc = $eDesc })
        }
        elseif ($e -match 'type:\s*"subsection"') {
            $eSect = if ($e -match 'section:\s*"([^"]*)"') { $Matches[1] } else { "" }
            $eName = if ($e -match 'name:\s*"([^"]*)"') { $Matches[1] } else { "" }
            $eDesc = if ($e -match 'desc:\s*"([^"]*)"') { $Matches[1] } else { "" }
            [void]$subsections.Add(@{ Section = $eSect; Name = $eName; Desc = $eDesc })
        }
        elseif ($e -match '\bs:\s*"') {
            $eS = if ($e -match '\bs:\s*"([^"]*)"') { $Matches[1] } else { "" }
            $eK = if ($e -match '\bk:\s*"([^"]*)"') { $Matches[1] } else { "" }
            $eG = if ($e -match '\bg:\s*"([^"]*)"') { $Matches[1] } else { "" }
            $eT = if ($e -match '\bt:\s*"([^"]*)"') { $Matches[1] } else { "" }
            $eD = if ($e -match '\bd:\s*"([^"]*)"') { $Matches[1] } else { "" }
            $eDefault = ""
            if ($e -match 'default:\s*"([^"]*)"') { $eDefault = $Matches[1] }
            elseif ($e -match 'default:\s*(true|false)') { $eDefault = $Matches[1] }
            elseif ($e -match 'default:\s*(0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)') { $eDefault = $Matches[1] }

            $eOptions = $null
            if ($e -match 'options:\s*\[([^\]]+)\]') {
                $q = [char]34
                $eOptions = ($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim($q) }) -join ', '
            }
            $eFmt = if ($e -match 'fmt:\s*"([^"]*)"') { $Matches[1] } else { $null }
            $eMin = if ($e -match '\bmin:\s*(0x[0-9A-Fa-f]+|-?\d+(?:\.\d+)?)') { $Matches[1] } else { $null }
            $eMax = if ($e -match '\bmax:\s*(0x[0-9A-Fa-f]+|-?\d+(?:\.\d+)?)') { $Matches[1] } else { $null }

            [void]$settings.Add(@{
                S = $eS; K = $eK; G = $eG; T = $eT; D = $eD
                Default = $eDefault; Options = $eOptions; Fmt = $eFmt
                Min = $eMin; Max = $eMax
                SL = $eS.ToLower(); KL = $eK.ToLower(); GL = $eG.ToLower()
                DL = $eD.ToLower()
            })
        }

        $entryText = ""
    }
}

# === Metadata filter modes ===
if ($Format -or $Type -or $HasBounds.IsPresent) {
    $filtered = [System.Collections.ArrayList]::new()
    foreach ($st in $settings) {
        if ($Format -and $st.Fmt -ne $Format) { continue }
        if ($Type -and $st.T -ne $Type) { continue }
        if ($HasBounds.IsPresent -and (-not $st.Min -and -not $st.Max)) { continue }
        [void]$filtered.Add($st)
    }

    $label = "Filtered settings"
    if ($Format) { $label = "Settings with fmt=$Format" }
    elseif ($Type) { $label = "Settings with type=$Type" }
    elseif ($HasBounds.IsPresent) { $label = "Settings with min/max bounds" }

    Write-Host ""
    Write-Host "  $label ($($filtered.Count)):" -ForegroundColor White
    Write-Host ""

    foreach ($st in $filtered) {
        $typeInfo = "type: $($st.T)"
        if ($st.Options) { $typeInfo += "  options: $($st.Options)" }
        $defaultInfo = "default: $($st.Default)"
        if ($st.Fmt) { $defaultInfo += " [fmt=$($st.Fmt)]" }
        if ($st.Min -or $st.Max) { $defaultInfo += " [min=$($st.Min) max=$($st.Max)]" }

        Write-Host "  [$($st.S)] $($st.K)  $($st.G)" -ForegroundColor Green
        Write-Host "    $typeInfo  $defaultInfo" -ForegroundColor DarkGray
        if ($st.D) {
            Write-Host "    $($st.D)" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    exit 0
}

# === No arguments: show section/group index ===
if (-not $Search -and -not $Section -and -not $Usage) {
    $totalCount = $settings.Count
    Write-Host ""
    Write-Host "  Config Registry Index, $totalCount settings" -ForegroundColor White
    Write-Host ""

    foreach ($sec in $sections) {
        $setCount = 0
        foreach ($st in $settings) { if ($st.S -eq $sec.Name) { $setCount++ } }
        Write-Host "  [$($sec.Name)] $($sec.Desc) - $setCount settings" -ForegroundColor Cyan

        foreach ($sub in $subsections) {
            if ($sub.Section -eq $sec.Name) {
                Write-Host "    - $($sub.Name): $($sub.Desc)" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host ""
    Write-Host "  Search:  query_config.ps1 <keyword>" -ForegroundColor DarkGray
    Write-Host "  List:    query_config.ps1 -Section <name>" -ForegroundColor DarkGray
    Write-Host "  Usage:   query_config.ps1 -Usage <propertyName>" -ForegroundColor DarkGray
    Write-Host "  Filter:  query_config.ps1 -Format hex | -Type int | -HasBounds" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# === Usage mode: find all consumers of cfg.PropertyName ===
if ($Usage) {
    # Strip cfg. prefix if provided
    $propertyName = $Usage -replace '^cfg\.', ''

    # Find the config entry by its g: (global/property) field
    # Also handles array section expanded names (e.g., Shader1_ShaderName → Shader{N}_ShaderName)
    $found = $null
    foreach ($st in $settings) {
        if ($st.G -eq $propertyName) {
            $found = $st
            break
        }
    }
    # If not found, try matching against {N} template patterns (array sections)
    if (-not $found) {
        foreach ($st in $settings) {
            if ($st.G -notlike '*{N}*') { continue }
            $parts = $st.G -split '\{N\}'
            $escapedParts = $parts | ForEach-Object { [regex]::Escape($_) }
            $pattern = '^' + ($escapedParts -join '\d+') + '$'
            if ($propertyName -match $pattern) {
                $found = $st
                break
            }
        }
    }

    if (-not $found) {
        Write-Host "  cfg.$propertyName not found in config registry." -ForegroundColor Red
        Write-Host "  Run with no arguments to see available sections, or search by keyword." -ForegroundColor DarkGray
        exit 1
    }

    # Show the definition
    $typeInfo = "type: $($found.T)"
    $defaultInfo = "default: $($found.Default)"
    if ($found.Fmt -eq 'hex') { $defaultInfo += " [hex]" }

    Write-Host ""
    Write-Host "  cfg.$propertyName" -ForegroundColor White
    Write-Host "    defined:  [$($found.S)] $($found.K)  $typeInfo  $defaultInfo" -ForegroundColor DarkGray

    # Pass 1: Search src/ (excluding src/lib/) for literal cfg.<propertyName>
    $srcPath = Join-Path $projectRoot "src"
    $srcFiles = Get-AhkSourceFiles $srcPath

    $needle = "cfg.$propertyName"
    $hitCount = 0
    $usageLines = [System.Collections.ArrayList]::new()
    foreach ($file in $srcFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        if ($text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $relPath = $file.FullName.Replace("$projectRoot\", '')
        $lines = Split-Lines $text
        for ($li = 0; $li -lt $lines.Count; $li++) {
            if ($lines[$li].IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                [void]$usageLines.Add("      ${relPath}:$($li + 1)")
                $hitCount++
            }
        }
    }

    # Pass 2: Detect dynamic property access (cfg.%expr%)
    # AHK v2 patterns:
    #   a) cfg.%"Shader" A_Index "_ShaderName"% — inline string literals in expression
    #   b) cfg.%prefix "Bg"% — variable + inline literal suffix
    #   c) cfg.%cfgProp% — fully variable (e.g., theme palette via _Theme_CfgHex)
    # For (a)/(b): extract string literals and check if they form fragments of propertyName.
    # For (c): check if the file contains string literals that decompose propertyName.
    $dynRx = [regex]::new('cfg\.%([^%]+)%')
    $litRx = [regex]::new('"([^"]+)"')
    $dynHitCount = 0
    $dynLines = [System.Collections.ArrayList]::new()
    $dynSeenLines = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($file in $srcFiles) {
        $relPath = $file.FullName.Replace("$projectRoot\", '')
        # Skip config_loader.ahk — its cfg.%entry.g% is the generic loader, not a real consumer
        if ($relPath -like '*config_loader.ahk') { continue }
        $text = [System.IO.File]::ReadAllText($file.FullName)
        if ($text.IndexOf('cfg.%') -lt 0) { continue }
        $lines = Split-Lines $text

        # Collect all string literals in the file for fallback matching (pattern c)
        $fileLits = $null

        for ($li = 0; $li -lt $lines.Count; $li++) {
            $line = $lines[$li]
            if ($line.IndexOf('cfg.%') -lt 0) { continue }
            $dynMatches = $dynRx.Matches($line)
            foreach ($dm in $dynMatches) {
                $expr = $dm.Groups[1].Value
                $exprLits = $litRx.Matches($expr)

                $matched = $false
                if ($exprLits.Count -gt 0) {
                    # Pattern (a)/(b): inline literals in the expression
                    $skeleton = ""
                    foreach ($lit in $exprLits) { $skeleton += $lit.Groups[1].Value }
                    if ($skeleton.Length -ge 2) {
                        $fragments = @()
                        foreach ($lit in $exprLits) { $fragments += [regex]::Escape($lit.Groups[1].Value) }
                        $fragPattern = $fragments -join '.*'
                        if ($propertyName -cmatch $fragPattern) { $matched = $true }
                    }
                } else {
                    # Pattern (c): fully variable — check if file has literals that compose propertyName
                    # E.g., theme palette: cfg.%cfgProp% where cfgProp = "Theme_Dark" + "Accent"
                    # Lazy-init: collect all 3+ char string literals from the entire file
                    if ($null -eq $fileLits) {
                        $fileLits = [System.Collections.ArrayList]::new()
                        $allLits = $litRx.Matches($text)
                        foreach ($al in $allLits) {
                            $v = $al.Groups[1].Value
                            if ($v.Length -ge 3) { [void]$fileLits.Add($v) }
                        }
                    }
                    # Require 2+ literal fragments that together cover most of the property name.
                    # Fragment 1 must match a prefix of propertyName, fragment 2 must cover the remainder.
                    $propLower = $propertyName.ToLower()
                    foreach ($fl in $fileLits) {
                        $flLower = $fl.ToLower()
                        # Fragment must match at a reasonable position in the property name
                        $idx = $propLower.IndexOf($flLower)
                        if ($idx -lt 0) { continue }
                        # Remove matched fragment and any surrounding underscores/digits
                        $before = if ($idx -gt 0) { $propLower.Substring(0, $idx) } else { '' }
                        $after = $propLower.Substring($idx + $flLower.Length)
                        $remainParts = @($before, $after) | Where-Object { $_.Trim('_0123456789').Length -ge 2 }
                        if ($remainParts.Count -eq 0) {
                            # Fragment + trivial remainder covers the property name
                            $matched = $true; break
                        }
                        # Check if all remaining parts appear in file literals
                        $allCovered = $true
                        foreach ($rp in $remainParts) {
                            $rpClean = $rp.Trim('_0123456789')
                            $partFound = $false
                            foreach ($fl2 in $fileLits) {
                                if ($fl2.ToLower() -eq $rpClean) { $partFound = $true; break }
                            }
                            if (-not $partFound) { $allCovered = $false; break }
                        }
                        if ($allCovered) { $matched = $true; break }
                    }
                }

                if ($matched) {
                    $lineRef = "      ${relPath}:$($li + 1)  (dynamic)"
                    if ($dynSeenLines.Add($lineRef)) {
                        [void]$dynLines.Add($lineRef)
                        $dynHitCount++
                    }
                }
            }
        }
    }

    $totalHits = $hitCount + $dynHitCount
    if ($totalHits -eq 0) {
        Write-Host "    used by: (none)" -ForegroundColor DarkGray
    } else {
        Write-Host "    used by:" -ForegroundColor DarkGray
        foreach ($line in $usageLines) {
            Write-Host $line -ForegroundColor Green
        }
        foreach ($line in $dynLines) {
            Write-Host $line -ForegroundColor Yellow
        }
    }

    Write-Host ""
    exit 0
}

# === Section mode: list all settings in a section ===
if ($Section) {
    $matched = [System.Collections.ArrayList]::new()
    foreach ($st in $settings) {
        if ($st.S -eq $Section) { [void]$matched.Add($st) }
    }
    if ($matched.Count -eq 0) {
        # Try case-insensitive partial match
        foreach ($st in $settings) {
            if ($st.S -like "*$Section*") { [void]$matched.Add($st) }
        }
    }

    if ($matched.Count -eq 0) {
        Write-Host "  No settings found in section: $Section" -ForegroundColor Red
        Write-Host "  Run with no arguments to see available sections." -ForegroundColor DarkGray
        exit 1
    }

    $sectionName = $matched[0].S
    $matchedCount = $matched.Count
    Write-Host ""
    Write-Host "  [$sectionName] - $matchedCount settings" -ForegroundColor White
    Write-Host ""

    foreach ($st in $matched) {
        $typeInfo = "type: $($st.T)"
        if ($st.Options) { $typeInfo += "  options: $($st.Options)" }
        $defaultInfo = "default: $($st.Default)"
        if ($st.Fmt) { $defaultInfo += " [fmt=$($st.Fmt)]" }
        if ($st.Min -or $st.Max) { $defaultInfo += " [min=$($st.Min) max=$($st.Max)]" }

        Write-Host "  [$sectionName] $($st.K)  $($st.G)" -ForegroundColor Green
        Write-Host "    $typeInfo  $defaultInfo" -ForegroundColor DarkGray
        if ($st.D) {
            Write-Host "    $($st.D)" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    exit 0
}

# === Fuzzy search mode ===
$searchLower = $Search.ToLower()
$results = [System.Collections.ArrayList]::new()

foreach ($st in $settings) {
    $score = 0

    # Exact key match
    if ($st.KL -eq $searchLower -or $st.GL -eq $searchLower) {
        $score = 100
    }
    # Key contains search term
    elseif ($st.KL.Contains($searchLower) -or $st.GL.Contains($searchLower)) {
        $score = 80
    }
    # Section name matches
    elseif ($st.SL.Contains($searchLower)) {
        $score = 40
    }
    # Description contains search term
    elseif ($st.DL.Contains($searchLower)) {
        $score = 20
    }

    if ($score -gt 0) {
        [void]$results.Add(@{ Setting = $st; Score = $score })
    }
}

if ($results.Count -eq 0) {
    Write-Host "  No matches for: $Search" -ForegroundColor Red
    Write-Host "  Run with no arguments to see available sections and groups." -ForegroundColor DarkGray
    exit 1
}

$sorted = $results | Sort-Object { $_.Score } -Descending

Write-Host ""
$resultCount = $results.Count
Write-Host "  Matches for [$Search] - $resultCount results:" -ForegroundColor White
Write-Host ""

foreach ($r in $sorted) {
    $st = $r.Setting
    $typeInfo = "type: $($st.T)"
    if ($st.Options) { $typeInfo += "  options: $($st.Options)" }
    $defaultInfo = "default: $($st.Default)"
    if ($st.Fmt) { $defaultInfo += " [fmt=$($st.Fmt)]" }
    if ($st.Min -or $st.Max) { $defaultInfo += " [min=$($st.Min) max=$($st.Max)]" }

    Write-Host "  [$($st.S)] $($st.K)  $($st.G)" -ForegroundColor Green
    Write-Host "    $typeInfo  $defaultInfo" -ForegroundColor DarkGray
    if ($st.D) {
        Write-Host "    $($st.D)" -ForegroundColor DarkGray
    }
}

Write-Host ""
