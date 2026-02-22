# query_function_visibility.ps1 - Function visibility query & enforcement
#
# Query tool + static analysis check for function visibility conventions.
# Enforces that functions prefixed with _ are only referenced within their
# declaring file - both direct calls _Func() and references passed to
# SetTimer, OnEvent, OnMessage, callbacks, etc. The _ prefix is the
# codebase convention for "internal to this file." If a _ function needs
# cross-file access, rename it to drop the _ prefix.
#
# This turns an emerged naming convention into a machine-enforced boundary.
#
# Query mode (default): Returns definition, visibility, and all callers.
#   powershell -File tools/query_function_visibility.ps1 <funcName>
#
# Discovery mode: Shows all cross-file calls to _ functions.
#   powershell -File tools/query_function_visibility.ps1 -Discover [-Detail]
#
# Enforcement mode (--check): Fails if any cross-file calls exist.
#   powershell -File tools/query_function_visibility.ps1 -Check
#
# Exit codes: 0 = pass (or query/discovery mode), 1 = violations found

[CmdletBinding()]
param(
    [string]$SourceDir,
    [Parameter(Position=0)][string]$Query,
    [switch]$Check,
    [switch]$Discover,
    [switch]$Detail
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Resolve paths ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}
$projectRoot = (Resolve-Path "$SourceDir\..").Path

# === Collect source files (exclude lib/) ===
$srcFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

if ($Query) {
    # Query mode: silent startup, output only the answer
    $queryKey = $Query.ToLower()
    $queryDef = $null
    $queryParams = ""
} elseif ($Discover) {
    Write-Host "  === Function Visibility Discovery ===" -ForegroundColor Cyan
    Write-Host "  Scanning $($srcFiles.Count) source files..." -ForegroundColor Cyan
} elseif ($Check) {
    Write-Host "  Checking function visibility in $($srcFiles.Count) files..." -ForegroundColor Cyan
} else {
    # No mode specified — show usage
    Write-Host "  Usage:" -ForegroundColor Cyan
    Write-Host "    query_function_visibility.ps1 <funcName>   Query a specific function" -ForegroundColor White
    Write-Host "    query_function_visibility.ps1 -Discover    Show all cross-file _ calls" -ForegroundColor White
    Write-Host "    query_function_visibility.ps1 -Check       Enforcement mode (pre-gate)" -ForegroundColor White
    exit 0
}

# === Helpers ===
function Clean-Line {
    param([string]$line)
    $trimmed = $line.TrimStart()
    if ($trimmed.Length -eq 0 -or $trimmed[0] -eq ';') { return '' }
    if ($trimmed.IndexOf('"') -lt 0 -and $trimmed.IndexOf(';') -lt 0) {
        return $trimmed
    }
    $cleaned = $trimmed -replace '"[^"]*"', '""'
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

# ============================================================
# Pass 1: Collect _ prefixed function definitions
# ============================================================
$pass1Sw = [System.Diagnostics.Stopwatch]::StartNew()

# funcDefs: funcName (lowercase) -> @{ Name; File; RelPath; Line }
$funcDefs = @{}
$fileCache = @{}
$fileCacheText = @{}

foreach ($file in $srcFiles) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $fileCacheText[$file.FullName] = $text
    $lines = $text -split "`r?`n"
    $fileCache[$file.FullName] = $lines
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    # Query mode: skip line parsing once the queried definition is found
    if ($Query -and $queryDef) { continue }

    $depth = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        $braces = Count-Braces $cleaned

        # Function definition at file scope (depth 0)
        # In Query mode, skip _ function collection once queryDef is found
        # (Pass 2 is skipped in Query mode, so funcDefs/privateFuncKeys are unused)
        if (-not ($Query -and $queryDef)) {
            if ($depth -eq 0 -and $cleaned -match '^\s*(?:static\s+)?(_\w+)\s*\(') {
                $fname = $Matches[1]
                $fkey = $fname.ToLower()
                if ($fkey -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                    if (-not $funcDefs.ContainsKey($fkey)) {
                        $funcDefs[$fkey] = @{
                            Name    = $fname
                            File    = $file.FullName
                            RelPath = $relPath
                            Line    = ($i + 1)
                        }
                    }
                }
            }
        }

        # Query mode: capture queried function definition during Pass 1
        if ($Query -and -not $queryDef -and $depth -eq 0 -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fn = $Matches[1]
            if ($fn.ToLower() -eq $queryKey -and $fn.ToLower() -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                $queryDef = @{
                    Name    = $fn
                    File    = $file.FullName
                    RelPath = $relPath
                    Line    = ($i + 1)
                }
                if ($lines[$i] -match '\(([^)]*)\)') {
                    $queryParams = $Matches[1].Trim()
                }
            }
        }

        $depth += $braces[0] - $braces[1]
        if ($depth -lt 0) { $depth = 0 }
    }
}

# Build lookup set for fast matching
$privateFuncKeys = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($key in $funcDefs.Keys) {
    [void]$privateFuncKeys.Add($key)
}

$pass1Sw.Stop()

if (-not $Query) {
    # Build combined regex for private function names (O(1) file pre-filter in Pass 2)
    $privateFuncRegex = $null
    if ($privateFuncKeys.Count -gt 0) {
        $escapedNames = @($privateFuncKeys | ForEach-Object { [regex]::Escape($funcDefs[$_].Name) })
        $privateFuncRegex = [regex]::new('(?i)(?:' + ($escapedNames -join '|') + ')', 'Compiled, IgnoreCase')
    }

    # Pre-compile per-line reference pattern (avoids recompilation per line)
    $privateCallPattern = [regex]::new('(?<![.\w])(_\w+)(?=\s*[\(,\)\s\.\[]|$)', 'Compiled')

    # ============================================================
    # Pass 2: Detect cross-file calls to _ functions
    # ============================================================
    $pass2Sw = [System.Diagnostics.Stopwatch]::StartNew()

    $violations = [System.Collections.ArrayList]::new()

    foreach ($file in $srcFiles) {
        $lines = $fileCache[$file.FullName]

        # Pre-filter: skip files without any private function name reference
        if ($privateFuncRegex -and -not $privateFuncRegex.IsMatch($fileCacheText[$file.FullName])) { continue }

        $relPath = $file.FullName.Replace("$projectRoot\", '')

        $depth = 0
        $inFunc = $false
        $funcDepth = -1
        $funcName = ""

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $cleaned = Clean-Line $lines[$i]
            if ($cleaned -eq '') { continue }

            $braces = Count-Braces $cleaned

            # Track function context for reporting
            if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
                $fn = $Matches[1].ToLower()
                if ($fn -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                    $inFunc = $true
                    $funcDepth = $depth
                    $funcName = $Matches[1]
                }
            }

            $depth += $braces[0] - $braces[1]
            if ($depth -lt 0) { $depth = 0 }

            if ($inFunc -and $depth -le $funcDepth) {
                $inFunc = $false
                $funcDepth = -1
            }

            # Find references to _ prefixed functions: both calls _Func() and
            # references _Func (passed to SetTimer, OnEvent, OnMessage, etc.)
            $callMatches = $privateCallPattern.Matches($cleaned)
            $seen = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)

            foreach ($cm in $callMatches) {
                $calledName = $cm.Groups[1].Value
                $calledKey = $calledName.ToLower()
                if ($seen.Contains($calledKey)) { continue }
                [void]$seen.Add($calledKey)

                if (-not $privateFuncKeys.Contains($calledKey)) { continue }

                $def = $funcDefs[$calledKey]

                # Skip same-file calls (that's the whole point)
                if ($def.File -eq $file.FullName) { continue }

                # Skip definition lines (file-scope _ function defs in other files
                # won't match because we already checked File equality)

                [void]$violations.Add(@{
                    CalledFunc = $def.Name
                    CallFile   = $file.FullName
                    CallRel    = $relPath
                    CallLine   = ($i + 1)
                    CallCode   = $lines[$i].Trim()
                    CallFunc   = $funcName
                    DefRel     = $def.RelPath
                    DefLine    = $def.Line
                })
            }
        }
    }

    $pass2Sw.Stop()
    $totalSw.Stop()
}

# ============================================================
# Query Mode: Return definition, visibility, and all callers
# ============================================================
if ($Query) {
    $funcDef = $queryDef
    $funcParams = $queryParams

    if (-not $funcDef) {
        Write-Host "  Unknown function: $Query" -ForegroundColor Red
        Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
        exit 1
    }

    $visibility = if ($funcDef.Name.StartsWith('_')) { "private" } else { "public" }
    $paramDisplay = if ($funcParams) { "($funcParams)" } else { "()" }

    Write-Host ""
    Write-Host "  $($funcDef.Name)$paramDisplay" -ForegroundColor White
    Write-Host "    defined:    $($funcDef.RelPath):$($funcDef.Line)" -ForegroundColor Cyan
    Write-Host "    visibility: $visibility" -ForegroundColor $(if ($visibility -eq 'private') { 'Yellow' } else { 'Green' })

    # Find all callers across all files
    $callers = [System.Collections.ArrayList]::new()
    $escaped = [regex]::Escape($funcDef.Name)

    foreach ($file in $srcFiles) {
        $qLines = $fileCache[$file.FullName]

        # Pre-filter: skip files that don't contain the function name at all
        if ($fileCacheText[$file.FullName].IndexOf($funcDef.Name, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

        $relPath = $file.FullName.Replace("$projectRoot\", '')

        $qDepth = 0
        $qInFunc = $false
        $qFuncDepth = -1
        $qCurFunc = ""

        for ($qi = 0; $qi -lt $qLines.Count; $qi++) {
            $cleaned = Clean-Line $qLines[$qi]
            if ($cleaned -eq '') { continue }

            $braces = Count-Braces $cleaned

            if (-not $qInFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
                $fn = $Matches[1]
                if ($fn.ToLower() -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                    $qInFunc = $true
                    $qFuncDepth = $qDepth
                    $qCurFunc = $fn
                }
            }

            $qDepth += $braces[0] - $braces[1]
            if ($qDepth -lt 0) { $qDepth = 0 }

            if ($qInFunc -and $qDepth -le $qFuncDepth) {
                $qInFunc = $false
                $qFuncDepth = -1
            }

            # Skip the definition line itself
            if ($file.FullName -eq $funcDef.File -and ($qi + 1) -eq $funcDef.Line) { continue }

            # Check for references (calls and function refs like SetTimer)
            if ($cleaned -match "(?<![.\w])$escaped(?=\s*[\(,\)\s\.\[]|$)") {
                $ctx = if ($qCurFunc -and $qInFunc) { $qCurFunc } else { "(file scope)" }
                [void]$callers.Add(@{
                    RelPath = $relPath
                    Line    = ($qi + 1)
                    Func    = $ctx
                })
            }
        }
    }

    if ($callers.Count -gt 0) {
        Write-Host "    called from:" -ForegroundColor DarkGray
        foreach ($c in $callers) {
            Write-Host "      $($c.RelPath):$($c.Line)  [$($c.Func)]" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "    called from: (no callers found)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 0
}

# ============================================================
# Discovery Mode
# ============================================================
if ($Discover) {
    Write-Host ""
    Write-Host "  Found $($funcDefs.Count) private (_ prefixed) functions across $($srcFiles.Count) files" -ForegroundColor White

    if ($violations.Count -gt 0) {
        Write-Host ""
        Write-Host "  --- CROSS-FILE CALLS TO PRIVATE FUNCTIONS ---" -ForegroundColor Yellow
        Write-Host ""

        # Group by called function
        $byFunc = @{}
        foreach ($v in $violations) {
            if (-not $byFunc.ContainsKey($v.CalledFunc)) {
                $byFunc[$v.CalledFunc] = [System.Collections.ArrayList]::new()
            }
            [void]$byFunc[$v.CalledFunc].Add($v)
        }

        $sorted = $byFunc.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending
        foreach ($entry in $sorted) {
            $fname = $entry.Key
            $calls = $entry.Value
            $def = $funcDefs[$fname.ToLower()]

            Write-Host "  $fname  " -ForegroundColor White -NoNewline
            Write-Host "($($calls.Count) cross-file call(s))" -ForegroundColor DarkGray
            Write-Host "    defined: $($def.RelPath):$($def.Line)" -ForegroundColor DarkGray

            foreach ($c in ($calls | Sort-Object { $_.CallRel })) {
                $ctx = if ($c.CallFunc) { " [$($c.CallFunc)]" } else { "" }
                Write-Host "    called:  $($c.CallRel):$($c.CallLine)$ctx" -ForegroundColor Red
                if ($Detail) {
                    Write-Host "             $($c.CallCode)" -ForegroundColor DarkGray
                }
            }
            Write-Host ""
        }

        # Count unique callers
        $uniqueCallerFiles = ($violations | ForEach-Object { $_.CallRel } | Sort-Object -Unique).Count
        $uniqueFuncs = $byFunc.Count

        Write-Host "  --- SUMMARY ---" -ForegroundColor Cyan
        Write-Host "    Private functions:       $($funcDefs.Count)" -ForegroundColor White
        Write-Host "    Cross-file calls:        $($violations.Count)" -ForegroundColor $(if ($violations.Count -gt 0) { "Yellow" } else { "Green" })
        Write-Host "    Functions exposed:        $uniqueFuncs" -ForegroundColor $(if ($uniqueFuncs -gt 0) { "Yellow" } else { "Green" })
        Write-Host "    Calling files:           $uniqueCallerFiles" -ForegroundColor White
        Write-Host "    Fix: rename to drop _ prefix (make explicitly public)" -ForegroundColor DarkGray
    } else {
        Write-Host ""
        Write-Host "  No cross-file calls to private functions found" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms (pass1: $($pass1Sw.ElapsedMilliseconds)ms, pass2: $($pass2Sw.ElapsedMilliseconds)ms)" -ForegroundColor Cyan
    exit 0
}

# ============================================================
# Enforcement Mode (--check)
# ============================================================
if ($violations.Count -eq 0) {
    Write-Host "  All calls respect visibility ($($funcDefs.Count) private functions)" -ForegroundColor Green
    Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 0
}

# Group violations by calling file
$violByFile = @{}
foreach ($v in $violations) {
    if (-not $violByFile.ContainsKey($v.CallRel)) {
        $violByFile[$v.CallRel] = [System.Collections.ArrayList]::new()
    }
    [void]$violByFile[$v.CallRel].Add($v)
}

Write-Host ""
Write-Host "  VISIBILITY VIOLATIONS ($($violations.Count)):" -ForegroundColor Red
Write-Host ""

foreach ($fileRel in ($violByFile.Keys | Sort-Object)) {
    $fileViols = $violByFile[$fileRel]
    Write-Host "  $fileRel" -ForegroundColor Yellow
    foreach ($v in $fileViols) {
        $ctx = if ($v.CallFunc) { " [$($v.CallFunc)]" } else { "" }
        Write-Host "    L$($v.CallLine)$ctx " -NoNewline -ForegroundColor White
        Write-Host "$($v.CalledFunc)" -NoNewline -ForegroundColor Red
        Write-Host " - defined in: $($v.DefRel):$($v.DefLine)" -ForegroundColor DarkGray
        Write-Host "      $($v.CallCode)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

$uniqueFuncs = ($violations | ForEach-Object { $_.CalledFunc } | Sort-Object -Unique).Count
Write-Host "  $($violations.Count) violation(s) across $($violByFile.Count) file(s) calling $uniqueFuncs private function(s)" -ForegroundColor Red
Write-Host "  Fix: rename the function to drop the _ prefix (make it explicitly public)" -ForegroundColor Yellow
Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
exit 1
