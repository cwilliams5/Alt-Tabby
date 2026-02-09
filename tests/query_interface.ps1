# query_interface.ps1 - File interface summary
#
# Shows public functions, private function count, and globals for a source file.
# Like help(module) for any .ahk file — shows what's available without reading
# the implementation.
#
# Usage:
#   powershell -File tests/query_interface.ps1 <filename>
#   powershell -File tests/query_interface.ps1 gui_overlay
#   powershell -File tests/query_interface.ps1 gui_overlay.ahk

param(
    [Parameter(Position=0)]
    [string]$FileName
)

$ErrorActionPreference = 'Stop'

if (-not $FileName) {
    Write-Host "  Usage: query_interface.ps1 <filename>" -ForegroundColor Yellow
    Write-Host "  Example: query_interface.ps1 gui_overlay" -ForegroundColor DarkGray
    exit 1
}

# Normalize filename
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)

# Find the file
$srcDir = (Resolve-Path "$PSScriptRoot\..\src").Path
$fileMatches = @(Get-ChildItem -Path $srcDir -Filter "$baseName.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

if ($fileMatches.Count -eq 0) {
    Write-Host "  No file found matching: $baseName.ahk" -ForegroundColor Red
    exit 1
}

$file = $fileMatches[0]
$lines = [System.IO.File]::ReadAllLines($file.FullName)
$projectRoot = (Resolve-Path "$srcDir\..").Path
$relPath = $file.FullName.Replace("$projectRoot\", '')

# === Helpers ===
function Clean-Line {
    param([string]$line)
    $cleaned = $line -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace '\s;.*$', ''
    if ($cleaned -match '^\s*;') { return '' }
    return $cleaned
}

function Count-Braces {
    param([string]$line)
    $opens = 0; $closes = 0
    foreach ($c in $line.ToCharArray()) {
        if ($c -eq '{') { $opens++ }
        elseif ($c -eq '}') { $closes++ }
    }
    return @($opens, $closes)
}

function Strip-Nested {
    param([string]$s)
    $result = [System.Text.StringBuilder]::new($s.Length)
    $depth = 0
    foreach ($c in $s.ToCharArray()) {
        if ($c -eq '(' -or $c -eq '[') { $depth++ }
        elseif ($c -eq ')' -or $c -eq ']') { if ($depth -gt 0) { $depth-- } }
        elseif ($depth -eq 0) { [void]$result.Append($c) }
    }
    return $result.ToString()
}

$AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)
$AHK_BUILTINS = @('true', 'false', 'unset', 'this', 'super')

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

    $braces = Count-Braces $cleaned

    # Function definition at file scope
    if (-not $inFunc -and $depth -eq 0 -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
        $fname = $Matches[1]
        $fkey = $fname.ToLower()
        if ($fkey -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
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
    if (-not $inFunc -and $cleaned -match '^\s*global\s+(.+)') {
        $declPart = $Matches[1]
        $stripped = Strip-Nested $declPart
        foreach ($part in $stripped -split ',') {
            $trimmed = $part.Trim()
            if ($trimmed -match '^(\w+)') {
                $gName = $Matches[1]
                if ($gName.Length -ge 2 -and $gName -notin $AHK_BUILTINS) {
                    [void]$globals.Add($gName)
                }
            }
        }
    }

    $depth += $braces[0] - $braces[1]
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
