# query_function.ps1 - Extract function body by name
#
# Shows a function's full implementation without loading the entire source file.
# Reduces context bloat when investigating "what does this function do?" questions.
#
# Usage:
#   powershell -File tools/query_function.ps1 <funcName>
#   powershell -File tools/query_function.ps1 GUI_Show
#   powershell -File tools/query_function.ps1 _GUI_BuildLayout

param(
    [Parameter(Position=0)]
    [string]$FuncName
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_query_helpers.ps1"

if (-not $FuncName) {
    Write-Host "  Usage: query_function.ps1 <funcName>" -ForegroundColor Yellow
    Write-Host "  Example: query_function.ps1 GUI_Show" -ForegroundColor DarkGray
    exit 1
}

# === Resolve paths ===
$srcDir = (Resolve-Path "$PSScriptRoot\..\src").Path
$projectRoot = (Resolve-Path "$srcDir\..").Path

# === Collect source files (including lib/) ===
$srcFiles = Get-AhkSourceFiles $srcDir -IncludeLib

# === Search all files for the function ===
$found = $null

foreach ($file in $srcFiles) {
    # File-level pre-filter: ReadAllText for IndexOf, split only on match
    $fileText = [System.IO.File]::ReadAllText($file.FullName)
    if ($fileText.IndexOf($FuncName, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

    $lines = Split-Lines $fileText

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

        $braceOpen = $cleaned.Length - $cleaned.Replace('{','').Length
        $braceClose = $cleaned.Length - $cleaned.Replace('}','').Length

        # Function definition at file scope
        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            $fkey = $fname.ToLower()
            if (-not $AHK_KEYWORDS_SET.Contains($fkey) -and $cleaned.Contains('{')) {
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

                    # Walk backwards to capture leading comment block
                    $commentLines = @()
                    $ci = $i - 1
                    while ($ci -ge 0) {
                        $cTrimmed = $lines[$ci].TrimStart()
                        if ($cTrimmed -match '^\s*;') {
                            # Comment line — prepend
                            $commentLines = @($lines[$ci]) + $commentLines
                            $ci--
                        } elseif ($cTrimmed -eq '') {
                            # Blank line — skip over it (might separate comment groups)
                            # But only if there's a comment above it
                            if ($ci -gt 0 -and $lines[$ci - 1].TrimStart() -match '^\s*;') {
                                $commentLines = @($lines[$ci]) + $commentLines
                                $ci--
                            } else {
                                break
                            }
                        } else {
                            break
                        }
                    }
                    if ($commentLines.Count -gt 0) {
                        $startLine = $ci + 1
                    }

                    # Now find the end of this function
                    $funcBody = @($commentLines) + @($lines[$i])
                    $currentDepth = $depth + $braceOpen - $braceClose

                    for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                        $funcBody += $lines[$j]
                        $jCleaned = Clean-Line $lines[$j]
                        if ($jCleaned -ne '') {
                            $currentDepth += ($jCleaned.Length - $jCleaned.Replace('{','').Length) - ($jCleaned.Length - $jCleaned.Replace('}','').Length)
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

        $depth += $braceOpen - $braceClose
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
