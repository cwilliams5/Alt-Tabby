# check_globals.ps1 - Static analysis for AHK v2 undeclared global references
# Pre-gate test: runs before any AHK process launches.
# Catches functions that use file-scope globals without a 'global' declaration,
# which silently become empty strings with #Warn VarUnset, Off.
#
# Scans both src/ and tests/ files:
#   - src/ functions are checked against ALL src/ file-scope globals (cross-file)
#   - test functions are checked against SAME-FILE globals only (per-file)
#
# Test files use per-file scoping because:
#   1. Test functions access production globals via #Include (compile-time),
#      not via separate compilation units — no 'global' declaration needed
#   2. Object literal initializers in test mocks (e.g. { idleStreak: 0 }) would
#      leak property names into the global set, causing false positives
#
# Usage: powershell -File tests\check_globals.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = undeclared references found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Configuration ===
$MIN_GLOBAL_NAME_LENGTH = 2
$AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)

# AHK built-in identifiers that should never be treated as user globals
$AHK_BUILTINS = @('true', 'false', 'unset', 'this', 'super')

# === Helpers ===
function Clean-Line {
    param([string]$line)
    # Fast-path for common cases (avoids regex overhead on most lines)
    if ($line.Length -eq 0) { return '' }
    $trimmed = $line.TrimStart()
    if ($trimmed.Length -eq 0) { return '' }
    if ($trimmed[0] -eq ';') { return '' }
    # Only do expensive regex if line actually has quotes or semicolons
    $cleaned = $line
    if ($line.IndexOf('"') -ge 0) {
        $cleaned = $cleaned -replace '"[^"]*"', '""'
    }
    if ($cleaned.IndexOf(';') -ge 0) {
        $cleaned = $cleaned -replace '\s;.*$', ''
    }
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
    # Remove content inside balanced () and [] to prevent values like
    # Map("key", true, "key2", false) from leaking into comma-split
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

function Extract-GlobalNames {
    # Parse a global declaration line's content (after "global ") into variable names
    # Handles: global a, b := value, c := Map("k", true), d
    param([string]$decl)
    $names = @()
    $stripped = Strip-Nested $decl
    foreach ($part in $stripped -split ',') {
        $trimmed = $part.Trim()
        if ($trimmed -match '^(\w+)') {
            $name = $Matches[1]
            if ($name.Length -ge $MIN_GLOBAL_NAME_LENGTH -and $name -notin $AHK_BUILTINS) {
                $names += $name
            }
        }
    }
    return $names
}

# === Resolve source directory ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$projectRoot = (Resolve-Path "$SourceDir\..").Path
$srcFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })
$testsDir = Join-Path $projectRoot "tests"
$testFiles = @()
$testsDirNorm = ""
if (Test-Path $testsDir) {
    $testFiles = @(Get-ChildItem -Path $testsDir -Filter "*.ahk" -Recurse)
    $testsDirNorm = [System.IO.Path]::GetFullPath($testsDir).ToLower().TrimEnd('\') + '\'
}
$allFiles = $srcFiles + $testFiles
Write-Host "  Scanning $($allFiles.Count) files ($($srcFiles.Count) src + $($testFiles.Count) tests) for undeclared global references..." -ForegroundColor Cyan

# ============================================================
# Pass 1: Collect file-scope global variable names
#   - src/ globals go into $fileGlobals (shared across all src/ functions)
#   - test globals go into $testPerFileGlobals (per-file, isolated)
# ============================================================
$pass1Sw = [System.Diagnostics.Stopwatch]::StartNew()
$fileGlobals = @{}  # globalName -> "relpath:lineNum" (src/ only)
$testPerFileGlobals = @{}  # filepath -> @{ globalName -> "relpath:lineNum" }
$testGlobalCount = 0
$fileCache = @{}  # path -> string[] (reused in Pass 2)
$fileCacheText = @{}  # path -> joined string (for pre-filter)

foreach ($file in $allFiles) {
    $isTestFile = $testsDirNorm -and $file.FullName.ToLower().StartsWith($testsDirNorm)
    $localGlobals = @{}  # per-file collection for test files

    $text = [System.IO.File]::ReadAllText($file.FullName)
    $fileCacheText[$file.FullName] = $text
    $lines = $text -split "`r?`n"
    $fileCache[$file.FullName] = $lines
    $depth = 0
    $inFunc = $false
    $funcDepth = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        $braces = Count-Braces $cleaned

        # Detect function/method start (when not already inside one)
        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1].ToLower()
            if ($fname -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                $inFunc = $true
                $funcDepth = $depth
            }
        }

        $depth += $braces[0] - $braces[1]

        # End of function
        if ($inFunc -and $depth -le $funcDepth) {
            $inFunc = $false
            $funcDepth = -1
        }

        # Collect globals when NOT inside a function body
        if (-not $inFunc -and $cleaned -match '^\s*global\s+(.+)') {
            $relPath = $file.FullName.Replace("$projectRoot\", '')
            foreach ($gName in (Extract-GlobalNames $Matches[1])) {
                if ($isTestFile) {
                    if (-not $localGlobals.ContainsKey($gName)) {
                        $localGlobals[$gName] = "${relPath}:$($i + 1)"
                    }
                } else {
                    if (-not $fileGlobals.ContainsKey($gName)) {
                        $fileGlobals[$gName] = "${relPath}:$($i + 1)"
                    }
                }
            }
        }
    }

    if ($isTestFile -and $localGlobals.Count -gt 0) {
        $testPerFileGlobals[$file.FullName] = $localGlobals
        $testGlobalCount += $localGlobals.Count
    }
}
$pass1Sw.Stop()

# Build combined regex for src/ global names (O(1) file pre-filter in Pass 2)
$srcGlobalRegex = $null
if ($fileGlobals.Count -gt 0) {
    $escapedNames = @($fileGlobals.Keys | ForEach-Object { [regex]::Escape($_) })
    $srcGlobalRegex = [regex]::new('(?:' + ($escapedNames -join '|') + ')', 'Compiled')
}

# Pre-compile per-global boundary regex (avoids re-parsing \b patterns in inner loop)
$globalBoundaryRegex = @{}
foreach ($gName in $fileGlobals.Keys) {
    $e = [regex]::Escape($gName)
    $globalBoundaryRegex[$gName] = [regex]::new("\b$e\b")
}

# ============================================================
# Pass 2: Check every function for undeclared global references
#   - src/ functions checked against $fileGlobals (all src/ globals)
#   - test functions checked against their own file's globals only
# ============================================================
$pass2Sw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()
$phantomIssues = [System.Collections.ArrayList]::new()
$funcCount = 0

foreach ($file in $allFiles) {
    $isTestFile = $testsDirNorm -and $file.FullName.ToLower().StartsWith($testsDirNorm)

    # Determine which globals set to check against
    if ($isTestFile) {
        if ($testPerFileGlobals.ContainsKey($file.FullName)) {
            $checkGlobals = $testPerFileGlobals[$file.FullName]
        } else {
            continue  # No file-scope globals in this test file — nothing to check
        }
    } else {
        $checkGlobals = $fileGlobals
    }

    $lines = $fileCache[$file.FullName]

    # Pre-filter: skip files that reference no globals (avoids parsing function boundaries)
    $joinedText = $fileCacheText[$file.FullName]
    if (-not $isTestFile) {
        # For src files, use pre-built combined regex (O(1) vs O(N) IndexOf)
        if (-not $srcGlobalRegex.IsMatch($joinedText)) { continue }
    } else {
        # For test files, per-file global set is small — IndexOf loop is fine
        $hasAnyGlobal = $false
        foreach ($gName in $checkGlobals.Keys) {
            if ($joinedText.IndexOf($gName, [System.StringComparison]::Ordinal) -ge 0) {
                $hasAnyGlobal = $true; break
            }
        }
        if (-not $hasAnyGlobal) { continue }
    }

    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""
    $funcStartLine = 0
    $funcDeclaredGlobals = @{}
    $funcParams = @{}
    $funcLocals = @{}
    $funcBodyLines = [System.Collections.ArrayList]::new()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]

        # Detect function start (not inside another function)
        if (-not $inFunc -and $cleaned -ne '' -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(([^)]*)\)') {
            $fname = $Matches[1]
            $paramStr = $Matches[2]
            if ($fname.ToLower() -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcStartLine = $i + 1
                $funcDepth = $depth
                $funcDeclaredGlobals = @{}
                $funcGlobalDeclLines = @{}
                $funcLocals = @{}
                $funcParams = @{}
                $funcBodyLines = [System.Collections.ArrayList]::new()
                $funcCount++

                # Extract parameter names (handle &ref, *variadic, default values)
                foreach ($p in $paramStr -split ',') {
                    if ($p.Trim() -match '^[&*]?(\w+)') {
                        $funcParams[$Matches[1]] = $true
                    }
                }
            }
        }

        $braces = Count-Braces $cleaned
        $depth += $braces[0] - $braces[1]

        if ($inFunc) {
            if ($cleaned -ne '') {
                # Collect global declarations inside function
                if ($cleaned -match '^\s*global\s+(.+)') {
                    foreach ($gn in (Extract-GlobalNames $Matches[1])) {
                        $funcDeclaredGlobals[$gn] = $true
                        if (-not $funcGlobalDeclLines.ContainsKey($gn)) {
                            $funcGlobalDeclLines[$gn] = @{ Line = ($i + 1); Raw = $lines[$i] }
                        }
                    }
                }
                # Collect static declarations
                if ($cleaned -match '^\s*static\s+(\w+)') {
                    $funcLocals[$Matches[1]] = $true
                }
                # Collect local declarations
                if ($cleaned -match '^\s*local\s+(.+)') {
                    foreach ($part in $Matches[1] -split ',') {
                        if ($part.Trim() -match '^(\w+)') {
                            $funcLocals[$Matches[1]] = $true
                        }
                    }
                }

                [void]$funcBodyLines.Add(@{ Line = ($i + 1); Text = $cleaned })
            }

            # End of function - analyze body
            if ($depth -le $funcDepth) {
                $texts = [string[]]::new($funcBodyLines.Count)
                for ($t = 0; $t -lt $funcBodyLines.Count; $t++) {
                    $texts[$t] = $funcBodyLines[$t].Text
                }
                $allText = [string]::Join(" ", $texts)

                # Extract all words from function body, check each against global set
                # O(words) instead of O(globals) — faster when words << globals
                $wordMatches = [regex]::Matches($allText, '\b[a-zA-Z_]\w+\b')
                $seenGlobals = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::Ordinal)

                foreach ($wm in $wordMatches) {
                    $gName = $wm.Value
                    if ($gName.Length -lt $MIN_GLOBAL_NAME_LENGTH) { continue }
                    if ($seenGlobals.Contains($gName)) { continue }
                    [void]$seenGlobals.Add($gName)
                    if (-not $checkGlobals.ContainsKey($gName)) { continue }
                    if ($funcDeclaredGlobals.ContainsKey($gName)) { continue }
                    if ($funcParams.ContainsKey($gName)) { continue }
                    if ($funcLocals.ContainsKey($gName)) { continue }

                    # Word was found via \b boundary in the regex, so boundary is guaranteed.
                    # Find first occurrence line for reporting.
                    $boundaryRx = $globalBoundaryRegex[$gName]
                    $foundLine = $null
                    foreach ($bodyLine in $funcBodyLines) {
                        if ($null -ne $boundaryRx) {
                            $lineMatch = $boundaryRx.IsMatch($bodyLine.Text)
                        } else {
                            # Fallback for test-file globals (not in pre-compiled set)
                            $escapedName = [regex]::Escape($gName)
                            $lineMatch = $bodyLine.Text -match "\b$escapedName\b"
                        }
                        if ($lineMatch -and $bodyLine.Text -notmatch '^\s*(?:global|static|local)\s') {
                            $foundLine = $bodyLine
                            break
                        }
                    }

                    if ($foundLine) {
                        [void]$issues.Add([PSCustomObject]@{
                            File     = $relPath
                            Line     = $foundLine.Line
                            Function = $funcName
                            Global   = $gName
                            Declared = $checkGlobals[$gName]
                        })
                    }
                }

                # Phantom global check: declared globals that don't exist at file scope
                # Skip test files — tests use complex #Include chains and function-scope
                # global initialization patterns that produce false positives.
                if (-not $isTestFile) {
                foreach ($gn in $funcDeclaredGlobals.Keys) {
                    if ($checkGlobals.ContainsKey($gn)) { continue }
                    $declInfo = $funcGlobalDeclLines[$gn]
                    if ($declInfo -and $declInfo.Raw -match 'lint-ignore:\s*phantom-global') { continue }
                    [void]$phantomIssues.Add([PSCustomObject]@{
                        File     = $relPath
                        Line     = $declInfo.Line
                        Function = $funcName
                        Global   = $gn
                    })
                }
                } # end if not test file

                $inFunc = $false
                $funcDepth = -1
            }
        }
    }
}
$pass2Sw.Stop()
$totalSw.Stop()

# ============================================================
# Report
# ============================================================
$timingLine = "  Timing: pass1=$($pass1Sw.ElapsedMilliseconds)ms  pass2=$($pass2Sw.ElapsedMilliseconds)ms  total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $($fileGlobals.Count) src globals, $testGlobalCount test globals (per-file), $funcCount functions, $($allFiles.Count) files"

$anyFailed = $false

if ($issues.Count -gt 0) {
    $anyFailed = $true
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) undeclared global reference(s) found." -ForegroundColor Red
    Write-Host "  These will silently become empty strings at runtime (#Warn VarUnset is Off)." -ForegroundColor Red
    Write-Host "  Fix: add 'global <name>' declaration inside the function." -ForegroundColor Yellow

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host "`n    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line): $($issue.Function)() uses '$($issue.Global)' without 'global' declaration" -ForegroundColor Red
            Write-Host "        (declared at $($issue.Declared))" -ForegroundColor DarkGray
        }
    }
}

if ($phantomIssues.Count -gt 0) {
    $anyFailed = $true
    Write-Host ""
    Write-Host "  FAIL: $($phantomIssues.Count) phantom global declaration(s) found." -ForegroundColor Red
    Write-Host "  These declare globals that don't exist at file scope - likely stale after refactoring." -ForegroundColor Red
    Write-Host "  The variable silently becomes an empty local instead of the intended global." -ForegroundColor Red
    Write-Host "  Fix: update the name to match the current global, or remove the declaration." -ForegroundColor Yellow
    Write-Host "  Suppress: add '; lint-ignore: phantom-global' on the declaration line." -ForegroundColor Yellow

    $grouped = $phantomIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host "`n    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line): $($issue.Function)() declares 'global $($issue.Global)' but no such global exists" -ForegroundColor Red
        }
    }
}

if ($anyFailed) {
    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: All global references properly declared" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
