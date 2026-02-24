# query_visibility.ps1 - Find public functions with few external callers
#
# Lists public functions that have 0 or 1 external callers across src/ (excluding lib/).
# Functions with 0 callers are definitely private (should have _ prefix).
# Functions with 1 caller may be candidates for inlining or making private.
#
# Usage:
#   powershell -File tools/query_visibility.ps1
#   powershell -File tools/query_visibility.ps1 -MinCallers 1
#
# Parameters:
#   -MinCallers  Show functions with at most this many external callers (0 or 1, default 0)

param(
    [ValidateRange(0, 1)]
    [int]$MinCallers = 0
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

. "$PSScriptRoot\_query_helpers.ps1"

# === Resolve paths ===
$srcDir = (Resolve-Path "$PSScriptRoot\..\src").Path
$projectRoot = (Resolve-Path "$srcDir\..").Path

# === Collect source files (exclude lib/) ===
$srcFiles = Get-AhkSourceFiles $srcDir

Write-Host ""
Write-Host "  Scanning $($srcFiles.Count) source files..." -ForegroundColor Cyan

# ============================================================
# Pass 1: Collect public function definitions
# ============================================================
$pass1Sw = [System.Diagnostics.Stopwatch]::StartNew()

# funcDefs: list of @{ Name; File; RelPath; Line }
$funcDefs = [System.Collections.ArrayList]::new()
$fileTexts = @{}

foreach ($file in $srcFiles) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $fileTexts[$file.FullName] = $text
    $lines = Split-Lines $text
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $depth = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        # Function definition at file scope (depth 0), public only (no _ prefix)
        if ($depth -eq 0 -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if (-not $AHK_KEYWORDS_SET.Contains($fname) -and -not $fname.StartsWith('_') -and $cleaned.Contains('{')) {
                [void]$funcDefs.Add(@{
                    Name    = $fname
                    File    = $file.FullName
                    RelPath = $relPath
                    Line    = ($i + 1)
                })
            }
        }

        $depth += ($cleaned.Length - $cleaned.Replace('{','').Length) - ($cleaned.Length - $cleaned.Replace('}','').Length)
        if ($depth -lt 0) { $depth = 0 }
    }
}

$pass1Sw.Stop()

# ============================================================
# Pass 2: Count external callers for each public function
# NOTE: O(F*N) looks invertible via a single combined regex scanning each file once,
# but a 320-way alternation regex is ~2x SLOWER in .NET (1612ms vs 727ms).
# The per-function IndexOf pre-filter + early exit is faster for this workload.
# ============================================================
$pass2Sw = [System.Diagnostics.Stopwatch]::StartNew()

$results = [System.Collections.ArrayList]::new()

# Pre-compile regex per function (avoids re-parsing in inner file loop)
foreach ($def in $funcDefs) {
    $escaped = [regex]::Escape($def.Name)
    $pattern = "(?<![.\w])$escaped(?=\s*[\(,\)\s\.\[]|$)"
    $def.CompiledRegex = [regex]::new($pattern, 'Compiled, IgnoreCase')
}

# Pre-build per-file word sets for O(1) name lookup (replaces IndexOf pre-filter)
$fileWordSets = @{}
foreach ($file in $srcFiles) {
    $words = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $script:_rxWord.Matches($fileTexts[$file.FullName])) {
        [void]$words.Add($m.Value)
    }
    $fileWordSets[$file.FullName] = $words
}

foreach ($def in $funcDefs) {
    $externalFiles = 0

    foreach ($file in $srcFiles) {
        # Skip the declaring file
        if ($file.FullName -eq $def.File) { continue }

        # Quick O(1) HashSet check before expensive regex
        if (-not $fileWordSets[$file.FullName].Contains($def.Name)) { continue }

        if ($def.CompiledRegex.IsMatch($fileTexts[$file.FullName])) {
            $externalFiles++
            # Once we exceed MinCallers threshold, no need to count further
            if ($externalFiles -gt $MinCallers) { break }
        }
    }

    if ($externalFiles -le $MinCallers) {
        [void]$results.Add(@{
            Name         = $def.Name
            RelPath      = $def.RelPath
            Line         = $def.Line
            ExternalFiles = $externalFiles
        })
    }
}

$pass2Sw.Stop()
$totalSw.Stop()

# ============================================================
# Output
# ============================================================
if ($results.Count -eq 0) {
    Write-Host "  No public functions found with <= $MinCallers external caller(s)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Scanned $($funcDefs.Count) public functions in $($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 0
}

# Sort by file then function name
$sorted = $results | Sort-Object { $_.RelPath }, { $_.Name }

# Group by file for display
$currentFile = ""
$zeroCount = 0
$oneCount = 0

Write-Host ""

foreach ($r in $sorted) {
    if ($r.RelPath -ne $currentFile) {
        if ($currentFile -ne "") { Write-Host "" }
        Write-Host "  $($r.RelPath)" -ForegroundColor White
        $currentFile = $r.RelPath
    }

    $callerLabel = if ($r.ExternalFiles -eq 0) { "0 callers" } else { "1 caller" }
    $color = if ($r.ExternalFiles -eq 0) { "Yellow" } else { "DarkGray" }
    Write-Host "    $($r.Name)  " -NoNewline -ForegroundColor $color
    Write-Host "($callerLabel)" -ForegroundColor DarkGray

    if ($r.ExternalFiles -eq 0) { $zeroCount++ } else { $oneCount++ }
}

Write-Host ""
Write-Host "  --- SUMMARY ---" -ForegroundColor Cyan
Write-Host "    Public functions scanned:  $($funcDefs.Count)" -ForegroundColor White
Write-Host "    0 external callers:        $zeroCount" -ForegroundColor $(if ($zeroCount -gt 0) { "Yellow" } else { "Green" })
if ($MinCallers -ge 1) {
    Write-Host "    1 external caller:         $oneCount" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms (pass1: $($pass1Sw.ElapsedMilliseconds)ms, pass2: $($pass2Sw.ElapsedMilliseconds)ms)" -ForegroundColor Cyan
