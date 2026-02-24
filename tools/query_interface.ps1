# query_interface.ps1 - File interface summary
#
# Shows public functions, private function count, and globals for a source file.
# Like help(module) for any .ahk file — shows what's available without reading
# the implementation.
#
# Usage:
#   powershell -File tools/query_interface.ps1 <filename>
#   powershell -File tools/query_interface.ps1 gui_overlay
#   powershell -File tools/query_interface.ps1 gui_overlay.ahk

param(
    [Parameter(Position=0)]
    [string]$FileName
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_query_helpers.ps1"

if (-not $FileName) {
    Write-Host "  Usage: query_interface.ps1 <filename>" -ForegroundColor Yellow
    Write-Host "  Example: query_interface.ps1 gui_overlay" -ForegroundColor DarkGray
    exit 1
}

# Normalize filename
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)

# Find the file
$srcDir = (Resolve-Path "$PSScriptRoot\..\src").Path
$fileMatches = @(Get-AhkSourceFiles $srcDir | Where-Object { $_.Name -eq "$baseName.ahk" })

if ($fileMatches.Count -eq 0) {
    Write-Host "  No file found matching: $baseName.ahk" -ForegroundColor Red
    exit 1
}

$file = $fileMatches[0]
$lines = [System.IO.File]::ReadAllLines($file.FullName)
$projectRoot = (Resolve-Path "$srcDir\..").Path
$relPath = $file.FullName.Replace("$projectRoot\", '')

# === Parse ===
$publicFuncs = [System.Collections.ArrayList]::new()
$privateFuncs = [System.Collections.ArrayList]::new()
$globals = [System.Collections.ArrayList]::new()

$depth = 0
$inFunc = $false
$funcDepth = -1

for ($i = 0; $i -lt $lines.Count; $i++) {
    $cleaned = Clean-Line $lines[$i]
    if ($cleaned -eq '') { continue }

    $braceOpen = $cleaned.Length - $cleaned.Replace('{', '').Length
    $braceClose = $cleaned.Length - $cleaned.Replace('}', '').Length

    # Function definition at file scope
    if (-not $inFunc -and $depth -eq 0 -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
        $fname = $Matches[1]
        if ((-not $AHK_KEYWORDS_SET.Contains($fname)) -and $cleaned.Contains('{')) {
            # Extract params
            $params = ""
            if ($lines[$i] -match '\(([^)]*)\)') {
                $params = $Matches[1].Trim()
            }

            $entry = @{ Name = $fname; Params = $params; Line = ($i + 1) }
            if ($fname.StartsWith('_')) {
                [void]$privateFuncs.Add($entry)
            } else {
                [void]$publicFuncs.Add($entry)
            }

            $inFunc = $true
            $funcDepth = $depth
        }
    }

    # Global declarations at file scope
    if (-not $inFunc -and $depth -eq 0 -and $cleaned -match '^\s*global\s+(.+)') {
        $declPart = $Matches[1]
        $stripped = Strip-Nested $declPart
        foreach ($part in $stripped -split ',') {
            $trimmed = $part.Trim()
            if ($trimmed -match '^(\w+)') {
                $gName = $Matches[1]
                if ($gName.Length -ge 2 -and (-not $AHK_BUILTINS_SET.Contains($gName))) {
                    [void]$globals.Add($gName)
                }
            }
        }
    }

    $depth += $braceOpen - $braceClose
    if ($depth -lt 0) { $depth = 0 }

    if ($inFunc -and $depth -le $funcDepth) {
        $inFunc = $false
        $funcDepth = -1
    }
}

# === Output ===
Write-Host ""
Write-Host "  $relPath" -ForegroundColor White
Write-Host ""

if ($publicFuncs.Count -gt 0 -or $privateFuncs.Count -gt 0) {
    Write-Host "  Functions ($($publicFuncs.Count) public, $($privateFuncs.Count) private):" -ForegroundColor Cyan
    foreach ($f in $publicFuncs) {
        $p = if ($f.Params) { "($($f.Params))" } else { "()" }
        Write-Host "    $($f.Name)$p" -ForegroundColor Green
    }
    if ($privateFuncs.Count -le 10) {
        foreach ($f in $privateFuncs) {
            $p = if ($f.Params) { "($($f.Params))" } else { "()" }
            Write-Host "    $($f.Name)$p" -ForegroundColor DarkGray
        }
    } else {
        for ($j = 0; $j -lt 5; $j++) {
            $f = $privateFuncs[$j]
            $p = if ($f.Params) { "($($f.Params))" } else { "()" }
            Write-Host "    $($f.Name)$p" -ForegroundColor DarkGray
        }
        Write-Host "    ... and $($privateFuncs.Count - 5) more private functions" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  Functions: (none)" -ForegroundColor DarkGray
}

Write-Host ""

if ($globals.Count -gt 0) {
    Write-Host "  Globals declared ($($globals.Count)):" -ForegroundColor Cyan
    $line = "    "
    $count = 0
    foreach ($g in ($globals | Sort-Object)) {
        if ($count -gt 0) { $line += ", " }
        $line += $g
        $count++
        if ($count -ge 4) {
            Write-Host $line -ForegroundColor DarkGray
            $line = "    "
            $count = 0
        }
    }
    if ($count -gt 0) {
        Write-Host $line -ForegroundColor DarkGray
    }
} else {
    Write-Host "  Globals declared: (none)" -ForegroundColor DarkGray
}

Write-Host ""
