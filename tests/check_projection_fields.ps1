# check_projection_fields.ps1 - Verify PROJECTION_FIELDS and _WS_ToItem stay in sync
#
# Parses src/store/windowstore.ahk to extract:
#   1. Field names from the PROJECTION_FIELDS array
#   2. Key names from _WS_ToItem's return object literal
# Compares them (excluding 'hwnd' which is always included separately).
# Reports mismatches if the two lists diverge.
#
# Usage: powershell -File tests\check_projection_fields.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = in sync, 1 = mismatch or parse error

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# === Resolve source directory ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$storeFile = Join-Path $SourceDir "store\windowstore.ahk"
if (-not (Test-Path $storeFile)) {
    Write-Host "  ERROR: windowstore.ahk not found: $storeFile" -ForegroundColor Red
    exit 1
}

$lines = [System.IO.File]::ReadAllLines($storeFile)
$content = [string]::Join("`n", $lines)

# === Extract PROJECTION_FIELDS ===
# The array spans multiple lines: global PROJECTION_FIELDS := ["field1", "field2", ...]
$projFieldNames = [System.Collections.ArrayList]::new()

if ($content -match '(?s)global\s+PROJECTION_FIELDS\s*:=\s*\[(.*?)\]') {
    $arrayContent = $Matches[1]
    $fieldMatches = [regex]::Matches($arrayContent, '"(\w+)"')
    foreach ($m in $fieldMatches) {
        [void]$projFieldNames.Add($m.Groups[1].Value)
    }
} else {
    Write-Host "  ERROR: Could not find PROJECTION_FIELDS array in windowstore.ahk" -ForegroundColor Red
    exit 1
}

if ($projFieldNames.Count -eq 0) {
    Write-Host "  ERROR: PROJECTION_FIELDS array is empty" -ForegroundColor Red
    exit 1
}

# === Extract _WS_ToItem return object keys ===
# Find the function and its return { ... } block
$toItemKeys = [System.Collections.ArrayList]::new()

# Find _WS_ToItem function start
$funcStartIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*_WS_ToItem\s*\(') {
        $funcStartIdx = $i
        break
    }
}

if ($funcStartIdx -lt 0) {
    Write-Host "  ERROR: Could not find _WS_ToItem function in windowstore.ahk" -ForegroundColor Red
    exit 1
}

# Collect lines from function start until closing brace (track brace depth)
$funcBody = [System.Text.StringBuilder]::new()
$depth = 0
$started = $false
for ($i = $funcStartIdx; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    [void]$funcBody.AppendLine($line)
    foreach ($c in $line.ToCharArray()) {
        if ($c -eq '{') { $depth++; $started = $true }
        elseif ($c -eq '}') { $depth-- }
    }
    if ($started -and $depth -le 0) { break }
}

$funcText = $funcBody.ToString()

# Extract keys from "return { key: value, key: value, ... }"
# Match "word:" patterns that are object literal keys (not inside strings)
$keyMatches = [regex]::Matches($funcText, '(?m)^\s*(\w+)\s*:\s*rec\.')
foreach ($m in $keyMatches) {
    $keyName = $m.Groups[1].Value
    [void]$toItemKeys.Add($keyName)
}

# Also catch the first key on the "return {" line itself
$returnLineMatch = [regex]::Match($funcText, 'return\s*\{\s*(\w+)\s*:')
if ($returnLineMatch.Success) {
    $firstKey = $returnLineMatch.Groups[1].Value
    if ($firstKey -notin $toItemKeys) {
        [void]$toItemKeys.Add($firstKey)
    }
}

if ($toItemKeys.Count -eq 0) {
    Write-Host "  ERROR: Could not extract any keys from _WS_ToItem return object" -ForegroundColor Red
    exit 1
}

# === Compare (excluding 'hwnd' which is always included separately) ===
$projSet = [System.Collections.Generic.HashSet[string]]::new()
foreach ($f in $projFieldNames) { [void]$projSet.Add($f) }

$toItemSet = [System.Collections.Generic.HashSet[string]]::new()
foreach ($k in $toItemKeys) {
    if ($k -ne 'hwnd') { [void]$toItemSet.Add($k) }
}

$inProjNotToItem = [System.Collections.ArrayList]::new()
foreach ($f in $projFieldNames) {
    if (-not $toItemSet.Contains($f)) {
        [void]$inProjNotToItem.Add($f)
    }
}

$inToItemNotProj = [System.Collections.ArrayList]::new()
foreach ($k in $toItemKeys) {
    if ($k -ne 'hwnd' -and -not $projSet.Contains($k)) {
        [void]$inToItemNotProj.Add($k)
    }
}

$sw.Stop()

if ($inProjNotToItem.Count -gt 0 -or $inToItemNotProj.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: PROJECTION_FIELDS/_WS_ToItem mismatch:" -ForegroundColor Red
    if ($inProjNotToItem.Count -gt 0) {
        Write-Host "    In PROJECTION_FIELDS but not _WS_ToItem: $($inProjNotToItem -join ', ')" -ForegroundColor Red
    }
    if ($inToItemNotProj.Count -gt 0) {
        Write-Host "    In _WS_ToItem but not PROJECTION_FIELDS: $($inToItemNotProj -join ', ')" -ForegroundColor Red
    }
    Write-Host "  Timing: $($sw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: PROJECTION_FIELDS and _WS_ToItem are in sync ($($projSet.Count) fields)" -ForegroundColor Green
    Write-Host "  Timing: $($sw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 0
}
