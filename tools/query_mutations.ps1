# query_mutations.ps1 - Detailed global mutation analysis
#
# Given a global variable name, shows every function that mutates it,
# with the conditions/guards around the mutation (Critical sections,
# if-guards, state checks). This is the "who can change this and when"
# question that query_global_ownership answers at file level but not
# at code-path level.
#
# Usage:
#   powershell -File tools/query_mutations.ps1 <globalName>
#   powershell -File tools/query_mutations.ps1 gGUI_State -Brief

param(
    [Parameter(Position=0)][string]$GlobalName,
    [switch]$Brief,
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

. "$PSScriptRoot\_query_helpers.ps1"

if (-not $GlobalName) {
    Write-Host "  Usage: query_mutations.ps1 <globalName> [-Brief]" -ForegroundColor Yellow
    Write-Host "  Examples:" -ForegroundColor DarkGray
    Write-Host "    query_mutations.ps1 gGUI_State          Full mutation analysis with guards" -ForegroundColor DarkGray
    Write-Host "    query_mutations.ps1 gGUI_State -Brief   Compact summary" -ForegroundColor DarkGray
    exit 1
}

# === Resolve paths ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}
$projectRoot = (Resolve-Path "$SourceDir\..").Path

# === Collect source files (include lib/ — query tool reports all mutations) ===
$srcFiles = Get-AhkSourceFiles $SourceDir -IncludeLib

$MUTATING_METHODS = 'Push|Pop|Delete|InsertAt|RemoveAt|Set|Clear'

# ============================================================
# Step 1: Find the file-scope global declaration
# ============================================================
$declaration = $null
$fileCache = @{}

foreach ($file in $srcFiles) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    if ($text.IndexOf($GlobalName, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

    $lines = Split-Lines $text
    $fileCache[$file.FullName] = $lines
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $depth = 0
    $inFunc = $false
    $funcDepth = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        if (-not $inFunc) {
            $m = $script:_rxFuncDef.Match($cleaned)
            if ($m.Success) {
                $fn = $m.Groups[1].Value
                if (-not $AHK_KEYWORDS_SET.Contains($fn) -and $cleaned.Contains('{')) {
                    $inFunc = $true
                    $funcDepth = $depth
                }
            }
        }

        $depth += ($cleaned.Length - $cleaned.Replace('{','').Length) - ($cleaned.Length - $cleaned.Replace('}','').Length)
        if ($depth -lt 0) { $depth = 0 }

        if ($inFunc -and $depth -le $funcDepth) {
            $inFunc = $false
            $funcDepth = -1
        }

        # File-scope global declaration
        if (-not $inFunc -and -not $declaration -and $cleaned -match '^\s*global\s+') {
            $stripped = Strip-Nested $cleaned
            if ($stripped -match "(?<!\w)$([regex]::Escape($GlobalName))(?!\w)") {
                $declaration = @{
                    File    = $file.FullName
                    RelPath = $relPath
                    Line    = ($i + 1)
                }
            }
        }
    }

    if ($declaration) { break }
}

if (-not $declaration) {
    Write-Host "  Unknown global: $GlobalName" -ForegroundColor Red
    # Suggest close matches
    $searchKey = $GlobalName.ToLower()
    $suggestions = @()
    foreach ($file in $srcFiles) {
        if (-not $fileCache.ContainsKey($file.FullName)) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            if ($text.IndexOf('global ', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $fileCache[$file.FullName] = Split-Lines $text
        }
        $lines = $fileCache[$file.FullName]
        foreach ($line in $lines) {
            if ($line -match '^\s*global\s+') {
                $wordMatches = $script:_rxWord.Matches($line)
                foreach ($wm in $wordMatches) {
                    $w = $wm.Value
                    if ($w -ieq 'global') { continue }
                    if ($w.ToLower().Contains($searchKey) -or $searchKey.Contains($w.ToLower())) {
                        $suggestions += $w
                    }
                }
            }
        }
    }
    $suggestions = $suggestions | Sort-Object -Unique | Select-Object -First 10
    if ($suggestions.Count -gt 0) {
        Write-Host "  Did you mean:" -ForegroundColor Yellow
        foreach ($s in $suggestions) {
            Write-Host "    $s" -ForegroundColor DarkGray
        }
    }
    exit 1
}

# ============================================================
# Step 2: Find all mutations with context
# ============================================================
$e = [regex]::Escape($GlobalName)
$mutPatterns = @(
    [regex]::new("(?<![.\w])$e\s*[:+\-\*\/\.]+\="),
    [regex]::new("(?<![.\w])$e\s*(\+\+|--)"),
    [regex]::new("(?<![.\w])$e\[.+?\]\s*[:+\-\*\/\.]+\="),
    [regex]::new("\b$e\.($MUTATING_METHODS)\s*\("),
    [regex]::new("\b$e\.\w+\s*[:+\-\*\/\.]+\=")
)

# Literal value regex for simple assignments
$rxLiteralAssign = [regex]::new("(?<![.\w])$e\s*:=\s*(.+)")

# Mutations: @{ File; RelPath; Line; Code; Func; Guards[]; LiteralValue }
$mutations = [System.Collections.ArrayList]::new()
$literalValues = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

foreach ($file in $srcFiles) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    if ($text.IndexOf($GlobalName, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

    if (-not $fileCache.ContainsKey($file.FullName)) {
        $fileCache[$file.FullName] = Split-Lines $text
    }
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""
    $funcStartIdx = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        if (-not $inFunc) {
            $m = $script:_rxFuncDef.Match($cleaned)
            if ($m.Success) {
                $fn = $m.Groups[1].Value
                if (-not $AHK_KEYWORDS_SET.Contains($fn) -and $cleaned.Contains('{')) {
                    $inFunc = $true
                    $funcDepth = $depth
                    $funcName = $fn
                    $funcStartIdx = $i
                }
            }
        }

        $depth += ($cleaned.Length - $cleaned.Replace('{','').Length) - ($cleaned.Length - $cleaned.Replace('}','').Length)
        if ($depth -lt 0) { $depth = 0 }

        if ($inFunc -and $depth -le $funcDepth) {
            $inFunc = $false
            $funcDepth = -1
        }

        if (-not $inFunc) { continue }

        # Test for mutation
        $isMutation = $mutPatterns[0].IsMatch($cleaned) -or
                      $mutPatterns[1].IsMatch($cleaned) -or
                      $mutPatterns[2].IsMatch($cleaned) -or
                      $mutPatterns[3].IsMatch($cleaned) -or
                      $mutPatterns[4].IsMatch($cleaned)

        if (-not $isMutation) { continue }

        # Extract guards by walking backwards from mutation line
        $guards = [System.Collections.ArrayList]::new()
        $hasCritical = $false

        # Walk backwards within the function to find guards
        $guardBraceDepth = 0
        $guardsFound = 0
        for ($gi = $i - 1; $gi -ge $funcStartIdx -and $guardsFound -lt 3; $gi--) {
            $gCleaned = Clean-Line $lines[$gi]
            if ($gCleaned -eq '') { continue }

            # Track brace depth going backwards
            $gBraceClose = $gCleaned.Length - $gCleaned.Replace('}','').Length
            $gBraceOpen = $gCleaned.Length - $gCleaned.Replace('{','').Length
            $guardBraceDepth += $gBraceClose - $gBraceOpen

            # Check for Critical "On"
            if (-not $hasCritical -and $gCleaned -match 'Critical\s+["'']On["'']') {
                $hasCritical = $true
            }

            # When we cross a brace boundary going up, look for if/while condition
            if ($guardBraceDepth -gt 0 -and ($gCleaned -match '^\s*(if|while|else\s+if)\s*\((.+)\)\s*\{?\s*$')) {
                $condition = $Matches[2].Trim()
                # Truncate long conditions
                if ($condition.Length -gt 60) { $condition = $condition.Substring(0, 57) + "..." }
                [void]$guards.Add($condition)
                $guardsFound++
                $guardBraceDepth--
            }
        }

        if ($hasCritical) {
            [void]$guards.Insert(0, 'Critical "On"')
        }

        # Extract literal value from raw line (not cleaned, since Clean-Line strips strings)
        $literalValue = $null
        $rawTrimmed = $lines[$i].Trim()
        $litMatch = $rxLiteralAssign.Match($rawTrimmed)
        if ($litMatch.Success) {
            $rhs = $litMatch.Groups[1].Value.Trim()
            # Check if it's a literal (string, number, true/false)
            if ($rhs -match '^"([^"]*)"$') {
                $literalValue = '"' + $Matches[1] + '"'
                [void]$literalValues.Add($Matches[1])
            } elseif ($rhs -match "^'([^']*)'$") {
                $literalValue = "'" + $Matches[1] + "'"
                [void]$literalValues.Add($Matches[1])
            } elseif ($rhs -match '^-?\d+(\.\d+)?$') {
                $literalValue = $rhs
                [void]$literalValues.Add($rhs)
            } elseif ($rhs -ieq 'true' -or $rhs -ieq 'false') {
                $literalValue = $rhs.ToLower()
                [void]$literalValues.Add($rhs.ToLower())
            } elseif ($rhs -match '^[A-Z_]+$' -and $rhs.Length -le 30) {
                # Likely a constant
                $literalValue = $rhs
            } else {
                $literalValue = '(dynamic)'
            }
        }

        [void]$mutations.Add(@{
            File         = $file.FullName
            RelPath      = $relPath
            Line         = ($i + 1)
            Code         = $lines[$i].Trim()
            Func         = $funcName
            Guards       = $guards
            LiteralValue = $literalValue
        })
    }
}

$totalSw.Stop()

# ============================================================
# Output
# ============================================================
Write-Host ""
Write-Host "  $GlobalName" -ForegroundColor White
Write-Host ""
Write-Host "  declared: $($declaration.RelPath):$($declaration.Line)" -ForegroundColor Cyan

if ($mutations.Count -eq 0) {
    Write-Host ""
    Write-Host "  no mutations found (read-only global or set only at declaration)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 0
}

Write-Host ""

if ($Brief) {
    # Brief mode
    Write-Host "  mutations ($($mutations.Count)):" -ForegroundColor Green
    foreach ($m in $mutations) {
        $basename = [System.IO.Path]::GetFileName($m.RelPath)
        $tags = @()
        $hasCrit = $false
        $hasGuard = $false
        foreach ($g in $m.Guards) {
            if ($g -eq 'Critical "On"') { $hasCrit = $true }
            else { $hasGuard = $true }
        }
        if ($hasCrit) { $tags += "Critical" }
        if ($hasGuard) { $tags += "guarded" }
        $tagStr = if ($tags.Count -gt 0) { "  [$($tags -join ', ')]" } else { "" }
        Write-Host "    $($m.Func.PadRight(24)) $basename`:$($m.Line)$tagStr" -ForegroundColor DarkGray
    }
} else {
    # Full mode
    Write-Host "  mutations ($($mutations.Count)):" -ForegroundColor Green

    # Group by function for cleaner output
    $byFunc = [ordered]@{}
    foreach ($m in $mutations) {
        $funcKey = "$($m.Func)|$($m.RelPath)"
        if (-not $byFunc.Contains($funcKey)) {
            $byFunc[$funcKey] = [System.Collections.ArrayList]::new()
        }
        [void]$byFunc[$funcKey].Add($m)
    }

    foreach ($entry in $byFunc.GetEnumerator()) {
        $muts = $entry.Value
        $first = $muts[0]
        $basename = [System.IO.Path]::GetFileName($first.RelPath)

        Write-Host ""
        Write-Host "    $($first.Func)()  " -ForegroundColor White -NoNewline
        Write-Host "$basename`:$($first.Line)" -ForegroundColor Cyan

        foreach ($m in $muts) {
            Write-Host "      $($m.Code)" -ForegroundColor DarkGray
        }

        # Show guards from the first mutation (typically all mutations in same function have same guards)
        if ($first.Guards.Count -gt 0) {
            $guardStr = $first.Guards -join ', '
            Write-Host "      guards: $guardStr" -ForegroundColor Yellow
        }
    }
}

# Values assigned
if ($literalValues.Count -gt 0) {
    Write-Host ""
    $sortedValues = $literalValues | Sort-Object
    $valueStr = ($sortedValues | ForEach-Object { "`"$_`"" }) -join ', '
    Write-Host "  values assigned: $valueStr" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
