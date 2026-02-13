# check_return_paths.ps1 - Detect functions with inconsistent return paths
#
# In AHK v2, a function that falls through without `return <value>` silently
# returns "". If a function returns a meaningful value on some code paths but
# uses bare `return` on others, callers get "" instead of the expected type.
# This causes downstream type errors that are hard to trace.
#
# Detection:
# 1. Parse function definitions and extract bodies (brace-depth tracking)
# 2. Classify each return statement:
#    - `return <expression>` = "value return"
#    - `return` (bare, end of statement) = "void return"
# 3. Flag functions that have BOTH value returns AND void returns
#
# Does NOT flag consistently-void functions (all bare returns / all fall-through).
# Excludes test files and lib/.
#
# Suppress: ; lint-ignore: mixed-returns on the function definition line.
#
# Usage: powershell -File tests\check_return_paths.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all pass, 1 = issues found

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

$projectRoot = (Resolve-Path "$SourceDir\..").Path
$RP_SUPPRESSION = 'lint-ignore: mixed-returns'

# === Read all source files (excluding lib/) ===
$allFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

$fileCache = @{}
foreach ($f in $allFiles) {
    $fileCache[$f.FullName] = [System.IO.File]::ReadAllLines($f.FullName)
}

# === Helpers ===

function RP_CleanLine {
    param([string]$line)
    $trimmed = $line.TrimStart()
    if ($trimmed.Length -eq 0 -or $trimmed[0] -eq ';') { return '' }
    # Fast path: no quotes or inline comments
    if ($trimmed.IndexOf('"') -lt 0 -and $trimmed.IndexOf("'") -lt 0 -and $trimmed.IndexOf(';') -lt 0) {
        return $trimmed
    }
    $cleaned = $trimmed -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace "'[^']*'", "''"
    $cleaned = $cleaned -replace '\s;.*$', ''
    return $cleaned
}

# === Main analysis ===
$issues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $i = 0
    while ($i -lt $lines.Count) {
        $cleaned = RP_CleanLine $lines[$i]

        # Detect function definition: FuncName(params) {
        # Must be at file scope (we track this via the outer while loop - we only
        # look for function defs when not inside another function)
        if ($cleaned -match '^(\w+)\s*\([^)]*\)\s*\{?\s*$') {
            $funcName = $Matches[1]
            $defLine = $i

            # Skip AHK keywords that look like functions
            if ($funcName -match '^(if|while|for|loop|switch|catch|else|try|class|return)$') {
                $i++; continue
            }

            # Check for suppression on the definition line
            $isSuppressed = $lines[$defLine].Contains($RP_SUPPRESSION)

            # Find opening brace (might be on same line or next line)
            $braceOnSameLine = $cleaned -match '\{\s*$'
            $funcStart = $i
            if (-not $braceOnSameLine) {
                # Look for opening brace on next non-empty line
                $j = $i + 1
                while ($j -lt $lines.Count) {
                    $nextCleaned = RP_CleanLine $lines[$j]
                    if ($nextCleaned -ne '') {
                        if ($nextCleaned -match '^\{') {
                            $funcStart = $j
                        } else {
                            # Not a function definition (no brace found)
                            $funcStart = -1
                        }
                        break
                    }
                    $j++
                }
                if ($funcStart -eq $i) {
                    # No brace found
                    $i++; continue
                }
                if ($funcStart -eq -1) {
                    $i++; continue
                }
            }

            # Extract function body by tracking brace depth
            $depth = 0
            $bodyStart = $funcStart
            $bodyEnd = -1
            $foundOpenBrace = $false

            for ($j = $bodyStart; $j -lt $lines.Count; $j++) {
                $bodyCleaned = RP_CleanLine $lines[$j]
                if ($bodyCleaned -eq '') { continue }

                foreach ($c in $bodyCleaned.ToCharArray()) {
                    if ($c -eq '{') {
                        $depth++
                        $foundOpenBrace = $true
                    }
                    elseif ($c -eq '}') {
                        $depth--
                        if ($foundOpenBrace -and $depth -eq 0) {
                            $bodyEnd = $j
                            break
                        }
                    }
                }
                if ($bodyEnd -ge 0) { break }
            }

            if ($bodyEnd -lt 0) {
                # Couldn't find end of function
                $i++; continue
            }

            # Analyze return statements within the function body
            $valueReturns = [System.Collections.ArrayList]::new()
            $voidReturns = [System.Collections.ArrayList]::new()

            # Track nested brace depth to skip inner functions/closures
            $innerDepth = 0
            $insideInnerFunc = $false

            for ($j = $bodyStart; $j -le $bodyEnd; $j++) {
                $bodyCleaned = RP_CleanLine $lines[$j]
                if ($bodyCleaned -eq '') { continue }

                # Track brace depth within the function
                $prevInnerDepth = $innerDepth
                foreach ($c in $bodyCleaned.ToCharArray()) {
                    if ($c -eq '{') { $innerDepth++ }
                    elseif ($c -eq '}') { $innerDepth-- }
                }

                # Skip the function's own opening brace line
                if ($j -eq $bodyStart) { continue }
                # Skip closing brace
                if ($j -eq $bodyEnd) { continue }

                # Detect nested function/closure definitions (depth > 1 means inner block)
                # We only care about returns at the TOP level of this function, not in
                # nested closures like (x) => { return y }
                # Inner functions start at depth > 1 with a function-like pattern
                if ($prevInnerDepth -ge 2) { continue }  # Inside nested block, but not a function
                # Actually, we need depth >= 2 meaning we're inside at least one inner brace
                # pair beyond the function's own braces. For simplicity, we check depth.
                # The function itself is depth 1 (after its opening brace). Nested blocks
                # (if/while/for) are also at depth >= 2 but their returns still belong
                # to this function. So we should NOT skip based on depth.
                # BUT nested function definitions (closures) do have their own returns.
                # Detect: funcName(...) { at depth 2+
                if ($bodyCleaned -match '^\w+\s*\([^)]*\)\s*\{' -and $prevInnerDepth -ge 1) {
                    # This is a nested function definition - we need to skip its body
                    # Track depth to skip until we're back to this level
                    $skipToDepth = $prevInnerDepth
                    $j++
                    while ($j -le $bodyEnd) {
                        $skipCleaned = RP_CleanLine $lines[$j]
                        if ($skipCleaned -ne '') {
                            foreach ($c in $skipCleaned.ToCharArray()) {
                                if ($c -eq '{') { $innerDepth++ }
                                elseif ($c -eq '}') { $innerDepth-- }
                            }
                            if ($innerDepth -le $skipToDepth) { break }
                        }
                        $j++
                    }
                    continue
                }

                # Check for return statements
                if ($bodyCleaned -match '(?<![.\w])return(?!\w)') {
                    # Determine if it's a value return or void return
                    # Value return: return <something>
                    # Void return: return (followed by end-of-line, comment, or closing brace)
                    $afterReturn = ''
                    if ($bodyCleaned -match '(?<![.\w])return\s+(.+)') {
                        $afterReturn = $Matches[1].Trim()
                    } elseif ($bodyCleaned -match '(?<![.\w])return$') {
                        $afterReturn = ''
                    } elseif ($bodyCleaned -match '(?<![.\w])return\s*$') {
                        $afterReturn = ''
                    } else {
                        # return immediately followed by something without space
                        # could be part of a variable name - skip
                        continue
                    }

                    # Clean up: remove trailing braces/comments from afterReturn
                    $afterReturn = $afterReturn.TrimEnd()
                    # Remove trailing } that might be closing an if block on same line
                    # e.g., "if (x) { return true }" - afterReturn is "true }"
                    # But we already stripped strings, so this should be rare
                    if ($afterReturn -match '^(.+?)\s*\}\s*$') {
                        $afterReturn = $Matches[1].Trim()
                    }

                    if ($afterReturn -eq '' -or $afterReturn -eq '}') {
                        [void]$voidReturns.Add($j + 1)  # 1-indexed line number
                    } else {
                        [void]$valueReturns.Add($j + 1)
                    }
                }
            }

            # Flag: function has BOTH value returns AND void returns
            if ($valueReturns.Count -gt 0 -and $voidReturns.Count -gt 0 -and -not $isSuppressed) {
                [void]$issues.Add([PSCustomObject]@{
                    File = $relPath
                    Line = ($defLine + 1)
                    Function = $funcName
                    ValueReturns = $valueReturns
                    VoidReturns = $voidReturns
                })
            }

            # Skip past this function body
            $i = $bodyEnd + 1
            continue
        }

        $i++
    }
}

# === Report ===
$sw.Stop()

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) function(s) with inconsistent return paths." -ForegroundColor Red
    Write-Host "  AHK v2 bare 'return' silently returns `"`"`. If some paths return a value"
    Write-Host "  and others use bare return, callers may get `"`"` instead of the expected type."
    Write-Host "  Fix: ensure all return paths return a value, or convert all to bare returns."
    Write-Host "  Suppress: add '; lint-ignore: mixed-returns' on the function definition line."
    foreach ($issue in $issues | Sort-Object File, Line) {
        Write-Host "    $($issue.File):$($issue.Line) $($issue.Function)()" -ForegroundColor Yellow
        $vrLines = ($issue.ValueReturns | ForEach-Object { "L$_" }) -join ', '
        $brLines = ($issue.VoidReturns | ForEach-Object { "L$_" }) -join ', '
        Write-Host "      Value returns: $vrLines"
        Write-Host "      Void returns:  $brLines"
    }
    Write-Host ""
    Write-Host "  Timing: $($sw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: All functions have consistent return paths" -ForegroundColor Green
    Write-Host "  Timing: $($sw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 0
}
