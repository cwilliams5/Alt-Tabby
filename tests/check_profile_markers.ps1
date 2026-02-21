# check_profile_markers.ps1 - Validate balanced Profiler.Enter/Leave per function
#
# For every function containing a Profiler.Enter() call, verifies:
#   1. Every return statement is preceded by Profiler.Leave() (early return problem)
#   2. The function ends with Profiler.Leave() before the closing brace
#   3. Enter/Leave calls are both tagged with ; @profile
#   4. Enter name matches containing function name
#
# Usage: powershell -File tests\check_profile_markers.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all pass, 1 = any imbalance

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'

# === Resolve source directory ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$errors = @()
$checkedFunctions = 0

# === Scan all .ahk files (excluding lib/) ===
$sourceFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

foreach ($file in $sourceFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$SourceDir\", "")

    # === Parse functions and find profiler calls ===
    # Track brace depth to identify function boundaries
    $inFunction = $false
    $funcName = ""
    $funcStartLine = 0
    $braceDepth = 0
    $funcLines = @()       # Lines within the current function
    $funcLineNums = @()    # Corresponding line numbers

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $trimmed = $line.Trim()
        $lineNum = $i + 1

        # Skip pure comments
        if ($trimmed.StartsWith(";")) { continue }

        if (-not $inFunction) {
            # Detect function definition: FuncName(params) {
            # Also matches static methods: ClassName.MethodName(params) {
            if ($trimmed -match '^(?:static\s+)?(\w[\w.]*)\s*\([^)]*\)\s*\{') {
                $inFunction = $true
                $funcName = $Matches[1]
                $funcStartLine = $lineNum
                $braceDepth = 1
                $funcLines = @()
                $funcLineNums = @()

                # Count additional braces on the opening line (rare but possible)
                $restOfLine = $trimmed.Substring($trimmed.IndexOf('{') + 1)
                $braceDepth += ([regex]::Matches($restOfLine, '\{')).Count
                $braceDepth -= ([regex]::Matches($restOfLine, '\}')).Count
                continue
            }
        } else {
            # Inside function — track braces
            # Strip strings and comments to avoid counting braces inside them
            $codePart = $trimmed -replace '"[^"]*"', '' -replace "'[^']*'", '' -replace ';.*$', ''

            $braceDepth += ([regex]::Matches($codePart, '\{')).Count
            $braceDepth -= ([regex]::Matches($codePart, '\}')).Count

            if ($braceDepth -gt 0) {
                $funcLines += $trimmed
                $funcLineNums += $lineNum
            }

            if ($braceDepth -le 0) {
                # Function ended — analyze it
                $hasEnter = $false
                $enterLine = -1
                $enterIdx = -1
                $enterName = ""
                $enterHasTag = $false

                for ($j = 0; $j -lt $funcLines.Count; $j++) {
                    $fl = $funcLines[$j]
                    if ($fl -match 'Profiler\.Enter\(\s*"([^"]+)"\s*\)') {
                        $hasEnter = $true
                        $enterLine = $funcLineNums[$j]
                        $enterIdx = $j
                        $enterName = $Matches[1]
                        $enterHasTag = $fl -match ';\s*@profile\s*$'
                    }
                }

                if ($hasEnter) {
                    $checkedFunctions++

                    # Check 1: Enter call must have ; @profile tag
                    if (-not $enterHasTag) {
                        $errors += "${relPath}:${enterLine}: Profiler.Enter() missing ; @profile tag in $funcName()"
                    }

                    # Check 2: Enter name should match function name
                    if ($enterName -ne $funcName) {
                        $errors += "${relPath}:${enterLine}: Profiler.Enter(`"$enterName`") does not match function name $funcName()"
                    }

                    # Check 3: Every return must be preceded by Profiler.Leave()
                    # Check 4: Function must end with Profiler.Leave() before closing brace
                    $lastLeaveIdx = -1
                    $leaveCount = 0

                    for ($j = 0; $j -lt $funcLines.Count; $j++) {
                        $fl = $funcLines[$j]

                        if ($fl -match 'Profiler\.Leave\(\)') {
                            $lastLeaveIdx = $j
                            $leaveCount++

                            # Verify Leave has ; @profile tag
                            if ($fl -notmatch ';\s*@profile\s*$') {
                                $errors += "${relPath}:$($funcLineNums[$j]): Profiler.Leave() missing ; @profile tag in $funcName()"
                            }
                        }

                        # Check return statements (skip returns before Profiler.Enter — they exit before profiling starts)
                        if ($fl -match '^\s*return\b' -and $j -gt $enterIdx) {
                            # Look backward for Profiler.Leave() — must be on previous non-empty line
                            # or on the same line (for single-line patterns)
                            $hasLeaveBeforeReturn = $false

                            # Check same line (e.g., "Profiler.Leave() ; @profile\n return")
                            if ($fl -match 'Profiler\.Leave\(\)') {
                                $hasLeaveBeforeReturn = $true
                            } else {
                                # Scan backward for the nearest Profiler.Leave()
                                for ($k = $j - 1; $k -ge 0; $k--) {
                                    $prev = $funcLines[$k]
                                    if ($prev -match '^\s*$') { continue }  # Skip blank lines
                                    if ($prev -match 'Profiler\.Leave\(\)') {
                                        $hasLeaveBeforeReturn = $true
                                    }
                                    break  # Only check the immediately preceding non-blank line
                                }
                            }

                            if (-not $hasLeaveBeforeReturn) {
                                $errors += "${relPath}:$($funcLineNums[$j]): return without preceding Profiler.Leave() in $funcName()"
                            }
                        }
                    }

                    # Check: function must end with Leave (last substantive line before closing brace)
                    # Find the last non-blank line in the function
                    $lastSubstantive = -1
                    for ($j = $funcLines.Count - 1; $j -ge 0; $j--) {
                        if ($funcLines[$j] -match '\S') {
                            $lastSubstantive = $j
                            break
                        }
                    }

                    if ($lastSubstantive -ge 0) {
                        $lastLine = $funcLines[$lastSubstantive]
                        # The last line should either be Profiler.Leave() itself,
                        # or a return preceded by Leave (already checked above),
                        # or the function naturally falls through after Leave
                        $endsWithLeave = $lastLine -match 'Profiler\.Leave\(\)'
                        $endsWithReturn = $lastLine -match '^\s*return\b'

                        if (-not $endsWithLeave -and -not $endsWithReturn) {
                            # Scan backward from function end looking for Leave within
                            # the last 15 lines. Handles try/catch patterns where Leave
                            # appears inside both try and catch blocks before the final }.
                            # Cap at 15 lines to avoid false matches from mid-function Leaves.
                            $foundLeaveNearEnd = $false
                            $scanLimit = [Math]::Max(0, $lastSubstantive - 15)
                            for ($j = $lastSubstantive - 1; $j -ge $scanLimit; $j--) {
                                $scanLine = $funcLines[$j]
                                if ($scanLine -match '^\s*$') { continue }  # Skip blank lines
                                if ($scanLine -match 'Profiler\.Leave\(\)') {
                                    $foundLeaveNearEnd = $true
                                    break
                                }
                            }
                            if (-not $foundLeaveNearEnd) {
                                $errors += "${relPath}:$($funcLineNums[$lastSubstantive]): function $funcName() with Profiler.Enter() does not end with Profiler.Leave()"
                            }
                        }
                    }

                    if ($leaveCount -eq 0) {
                        $errors += "${relPath}:${enterLine}: Profiler.Enter() in $funcName() has no matching Profiler.Leave()"
                    }
                }

                $inFunction = $false
                $funcName = ""
            }
        }
    }
}

# === Report ===
if ($errors.Count -gt 0) {
    Write-Host "  FAIL: $($errors.Count) profile marker issue(s) found:" -ForegroundColor Red
    foreach ($err in $errors) {
        Write-Host "    $err" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Fix: Ensure every Profiler.Enter() has balanced Profiler.Leave() calls" -ForegroundColor Yellow
    Write-Host "  at all return paths and at function end. Both must have ; @profile tag." -ForegroundColor Yellow
    exit 1
} else {
    $msg = "Profile markers: $checkedFunctions function(s) checked, all balanced"
    if ($checkedFunctions -eq 0) {
        $msg = "Profile markers: no instrumented functions found (OK)"
    }
    Write-Host "  $msg [PASS]" -ForegroundColor Green
    exit 0
}
