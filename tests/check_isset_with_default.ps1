# check_isset_with_default.ps1 - Static analysis for AHK v2 IsSet() on globals with defaults
# Detects globals declared with a default value (e.g., `global MyVar := 0`) where
# `IsSet(MyVar)` is later called. In AHK v2, IsSet() returns true for ANY assigned
# value (including 0, false, ""), so such checks are always true -- likely a bug.
#
# The developer probably intended to declare `global MyVar` (no value) so that
# IsSet() returns false until the variable is explicitly configured.
#
# Usage: powershell -File tests\check_isset_with_default.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = issues found
# Suppression: add `; lint-ignore: isset-with-default` on the IsSet() line

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Helpers ===
function Clean-Line {
    param([string]$line)
    # Remove quoted strings to avoid false matches on variable names inside strings
    $cleaned = $line -replace '"[^"]*"', '""'
    # Remove single-quoted strings
    $cleaned = $cleaned -replace "'[^']*'", "''"
    # Remove full-line comments
    if ($cleaned -match '^\s*;') { return '' }
    # Remove end-of-line comments (semicolon preceded by whitespace)
    $cleaned = $cleaned -replace '\s;.*$', ''
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

# === Resolve source directory ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$projectRoot = (Resolve-Path "$SourceDir\..").Path
$files = Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse
Write-Host "  Scanning $($files.Count) files for IsSet() on globals with default values..." -ForegroundColor Cyan

# ============================================================
# Phase 1: Collect file-scope global declarations WITH defaults
# Pattern: `global VarName := value` at brace depth 0
# ============================================================
$phase1Sw = [System.Diagnostics.Stopwatch]::StartNew()

# Map: varName -> @{ Name; File (relative); Line }
$globalsWithDefaults = @{}

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $cleaned = Clean-Line $raw
        if ($cleaned -eq '') {
            continue
        }

        # Track brace depth to know if we are at file scope
        $braces = Count-Braces $cleaned

        # Only look at file-scope (depth == 0) global declarations
        if ($depth -eq 0 -and $cleaned -match '^\s*global\s+(.+)') {
            $declContent = $Matches[1]

            # Handle multi-var declarations: global a := 1, b, c := 2
            # Split on commas, but respect nested parens/brackets
            $parts = @()
            $parenDepth = 0
            $current = [System.Text.StringBuilder]::new()
            foreach ($ch in $declContent.ToCharArray()) {
                if ($ch -eq '(' -or $ch -eq '[') { $parenDepth++ }
                elseif ($ch -eq ')' -or $ch -eq ']') { if ($parenDepth -gt 0) { $parenDepth-- } }
                if ($ch -eq ',' -and $parenDepth -eq 0) {
                    $parts += $current.ToString()
                    [void]$current.Clear()
                } else {
                    [void]$current.Append($ch)
                }
            }
            $parts += $current.ToString()

            foreach ($part in $parts) {
                $trimmed = $part.Trim()
                # Match: VarName := something
                if ($trimmed -match '^(\w+)\s*:=') {
                    $varName = $Matches[1]
                    if (-not $globalsWithDefaults.ContainsKey($varName)) {
                        $globalsWithDefaults[$varName] = @{
                            Name = $varName
                            File = $relPath
                            Line = ($i + 1)
                        }
                    }
                }
            }
        }

        $depth += $braces[0] - $braces[1]
        if ($depth -lt 0) { $depth = 0 }
    }
}
$phase1Sw.Stop()

Write-Host "  Phase 1: Found $($globalsWithDefaults.Count) globals with default values ($($phase1Sw.ElapsedMilliseconds)ms)" -ForegroundColor Cyan

# ============================================================
# Phase 2: Find IsSet(VarName) calls where VarName has a default
# ============================================================
$phase2Sw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()
$issetCallCount = 0

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]

        # Quick pre-filter: skip lines without IsSet
        if (-not $raw.Contains('IsSet')) { continue }

        # Check for suppression comment
        if ($raw -match ';\s*lint-ignore:\s*isset-with-default') { continue }

        $cleaned = Clean-Line $raw
        if ($cleaned -eq '') { continue }

        # Find all IsSet(VarName) occurrences on this line
        $regexMatches = [regex]::Matches($cleaned, '\bIsSet\(\s*(\w+)\s*\)')
        foreach ($m in $regexMatches) {
            $issetCallCount++
            $varName = $m.Groups[1].Value

            if ($globalsWithDefaults.ContainsKey($varName)) {
                $declInfo = $globalsWithDefaults[$varName]
                [void]$issues.Add([PSCustomObject]@{
                    IsSetFile = $relPath
                    IsSetLine = ($i + 1)
                    VarName   = $varName
                    DeclFile  = $declInfo.File
                    DeclLine  = $declInfo.Line
                })
            }
        }
    }
}
$phase2Sw.Stop()
$totalSw.Stop()

# ============================================================
# Report
# ============================================================
$timingLine = "  Timing: phase1=$($phase1Sw.ElapsedMilliseconds)ms  phase2=$($phase2Sw.ElapsedMilliseconds)ms  total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $($globalsWithDefaults.Count) globals-with-defaults, $issetCallCount IsSet() calls checked, $($files.Count) files"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) IsSet() call(s) on globals with default values." -ForegroundColor Red
    Write-Host "  IsSet() always returns true when the variable has ANY assigned value (including 0, false, `"`")." -ForegroundColor Red
    Write-Host "  Fix: declare the global without a value: 'global VarName' (not 'global VarName := 0')." -ForegroundColor Yellow
    Write-Host "  Suppress: add '; lint-ignore: isset-with-default' on the IsSet() line." -ForegroundColor Yellow

    $grouped = $issues | Group-Object IsSetFile
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host "`n    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object IsSetLine) {
            Write-Host "      Line $($issue.IsSetLine): IsSet($($issue.VarName)) - always true" -ForegroundColor Red
            Write-Host "        declared with default at $($issue.DeclFile):$($issue.DeclLine)" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: No IsSet() calls on globals with default values" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
