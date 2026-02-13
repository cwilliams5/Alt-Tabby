# query_function.ps1 - Extract function body by name
#
# Shows a function's full implementation without loading the entire source file.
# Reduces context bloat when investigating "what does this function do?" questions.
#
# Usage:
#   powershell -File tests/query_function.ps1 <funcName>
#   powershell -File tests/query_function.ps1 GUI_Show
#   powershell -File tests/query_function.ps1 _GUI_BuildLayout

param(
    [Parameter(Position=0)]
    [string]$FuncName
)

$ErrorActionPreference = 'Stop'

if (-not $FuncName) {
    Write-Host "  Usage: query_function.ps1 <funcName>" -ForegroundColor Yellow
    Write-Host "  Example: query_function.ps1 GUI_Show" -ForegroundColor DarkGray
    exit 1
}

# === Resolve paths ===
$srcDir = (Resolve-Path "$PSScriptRoot\..\src").Path
$projectRoot = (Resolve-Path "$srcDir\..").Path

# === Collect source files (exclude lib/) ===
$srcFiles = @(Get-ChildItem -Path $srcDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

# === Helpers ===
function Clean-Line {
    param([string]$line)
    $trimmed = $line.TrimStart()
    if ($trimmed.Length -eq 0 -or $trimmed[0] -eq ';') { return '' }
    if ($trimmed.IndexOf('"') -lt 0 -and $trimmed.IndexOf("'") -lt 0 -and $trimmed.IndexOf(';') -lt 0) {
        return $trimmed
    }
    $cleaned = $trimmed -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace "'[^']*'", "''"
    $cleaned = $cleaned -replace '\s;.*$', ''
    return $cleaned
}

function Count-Braces {
    param([string]$line)
    $opens = $line.Length - $line.Replace('{', '').Length
    $closes = $line.Length - $line.Replace('}', '').Length
    return @($opens, $closes)
}

$AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)

# === Search all files for the function ===
$found = $null

foreach ($file in $srcFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)

    # File-level pre-filter: skip files that don't contain the function name
    $joinedText = [string]::Join("`n", $lines)
    if ($joinedText.IndexOf($FuncName, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $depth = 0
    $inFunc = $false
    $funcDepth = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') {
            if ($inFunc -and $depth -le $funcDepth) {
                $inFunc = $false
                $funcDepth = -1
            }
            continue
        }

        $braces = Count-Braces $cleaned

        # Function definition at file scope
        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            $fkey = $fname.ToLower()
            if ($fkey -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                $inFunc = $true
                $funcDepth = $depth

                # Check if this is our target function (case-insensitive)
                if ($fname -ieq $FuncName) {
                    # Extract params from raw line
                    $params = ""
                    if ($lines[$i] -match '\(([^)]*)\)') {
                        $params = $Matches[1].Trim()
                    }

                    $startLine = $i
                    $startDepth = $depth

                    # Now find the end of this function
                    $funcBody = @($lines[$i])
                    $currentDepth = $depth + $braces[0] - $braces[1]

                    for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                        $funcBody += $lines[$j]
                        $jCleaned = Clean-Line $lines[$j]
                        if ($jCleaned -ne '') {
                            $jBraces = Count-Braces $jCleaned
                            $currentDepth += $jBraces[0] - $jBraces[1]
                        }
                        if ($currentDepth -le $startDepth) {
                            # Function closed
                            $found = @{
                                Name      = $fname
                                Params    = $params
                                RelPath   = $relPath
                                StartLine = $startLine + 1
                                EndLine   = $j + 1
                                Body      = $funcBody
                            }
                            break
                        }
                    }

                    # If we hit EOF without closing, still capture what we have
                    if (-not $found) {
                        $found = @{
                            Name      = $fname
                            Params    = $params
                            RelPath   = $relPath
                            StartLine = $startLine + 1
                            EndLine   = $lines.Count
                            Body      = $funcBody
                        }
                    }
                    break
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

    if ($found) { break }
}

# === Output ===
if (-not $found) {
    Write-Host "  Function not found: $FuncName" -ForegroundColor Red
    exit 1
}

$lineCount = $found.EndLine - $found.StartLine + 1
$visibility = if ($found.Name.StartsWith('_')) { "private" } else { "public" }

Write-Host ""
Write-Host "  $($found.Name)($($found.Params))" -ForegroundColor White
Write-Host "    file:       $($found.RelPath):$($found.StartLine)-$($found.EndLine) ($lineCount lines)" -ForegroundColor Cyan
Write-Host "    visibility: $visibility" -ForegroundColor DarkGray
Write-Host "  $('-' * 60)" -ForegroundColor DarkGray

# Print body with line numbers
for ($k = 0; $k -lt $found.Body.Count; $k++) {
    $lineNum = $found.StartLine + $k
    $prefix = "  {0,4}  " -f $lineNum
    Write-Host "$prefix$($found.Body[$k])" -ForegroundColor DarkGray
}

Write-Host ""
