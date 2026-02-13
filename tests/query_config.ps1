# query_config.ps1 - Config registry search
#
# Searches config_registry.ahk for settings matching a keyword.
# Returns semantic answers: section, key, type, default, description.
#
# Usage:
#   powershell -File tests/query_config.ps1                       (show section/group index)
#   powershell -File tests/query_config.ps1 theme                 (fuzzy search for "theme")
#   powershell -File tests/query_config.ps1 -Section GUI          (list all settings in a section)
#   powershell -File tests/query_config.ps1 -Usage GUI_RowHeight  (find all consumers of cfg.X)

param(
    [Parameter(Position=0)]
    [string]$Search,
    [string]$Section,
    [string]$Usage
)

$ErrorActionPreference = 'Stop'

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

            [void]$settings.Add(@{
                S = $eS; K = $eK; G = $eG; T = $eT; D = $eD
                Default = $eDefault; Options = $eOptions; Fmt = $eFmt
                SL = $eS.ToLower(); KL = $eK.ToLower(); GL = $eG.ToLower()
                DL = $eD.ToLower()
            })
        }

        $entryText = ""
    }
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
    Write-Host "  Search: query_config.ps1 <keyword>" -ForegroundColor DarkGray
    Write-Host "  List:   query_config.ps1 -Section <name>" -ForegroundColor DarkGray
    Write-Host "  Usage:  query_config.ps1 -Usage <propertyName>" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# === Usage mode: find all consumers of cfg.PropertyName ===
if ($Usage) {
    # Strip cfg. prefix if provided
    $propertyName = $Usage -replace '^cfg\.', ''

    # Find the config entry by its g: (global/property) field
    $found = $null
    foreach ($st in $settings) {
        if ($st.G -eq $propertyName) {
            $found = $st
            break
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

    # Grep src/ (excluding src/lib/) for cfg.<propertyName>
    $srcPath = Join-Path $projectRoot "src"
    $srcFiles = Get-ChildItem -Path $srcPath -Recurse -File -Filter "*.ahk" |
        Where-Object { $_.FullName -notlike "*\lib\*" }

    $matches = $srcFiles | Select-String -Pattern "cfg\.$propertyName" -CaseSensitive:$false

    if ($matches.Count -eq 0) {
        Write-Host "    used by: (none)" -ForegroundColor DarkGray
    } else {
        Write-Host "    used by:" -ForegroundColor DarkGray

        # Group by file, show relative paths
        $grouped = $matches | Group-Object { $_.Path }
        foreach ($group in $grouped) {
            $relPath = $group.Name.Substring($projectRoot.Length + 1)
            foreach ($m in $group.Group) {
                Write-Host "      ${relPath}:$($m.LineNumber)" -ForegroundColor Green
            }
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
        if ($st.Fmt -eq 'hex') { $defaultInfo += " [hex]" }

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
    if ($st.Fmt -eq 'hex') { $defaultInfo += " [hex]" }

    Write-Host "  [$($st.S)] $($st.K)  $($st.G)" -ForegroundColor Green
    Write-Host "    $typeInfo  $defaultInfo" -ForegroundColor DarkGray
    if ($st.D) {
        Write-Host "    $($st.D)" -ForegroundColor DarkGray
    }
}

Write-Host ""
