# check_v1_patterns.ps1 - Static analysis for AHK v1 holdover patterns
# Pre-gate test: runs before any AHK process launches.
# Catches v1 patterns that should not appear in AHK v2 code:
#   - Func("Name") — use direct function references
#   - %var% — legacy variable dereferencing (excludes %A_*% in #Include)
#   - Removed v1 commands (IfEqual, StringReplace, SetEnv, etc.)
#
# Usage: powershell -File tests\check_v1_patterns.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = v1 patterns found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Configuration ===

# Removed v1 commands (case-insensitive match at start of line)
$V1_COMMANDS = @(
    'IfEqual', 'IfNotEqual', 'IfGreater', 'IfLess',
    'IfInString', 'IfNotInString',
    'StringLeft', 'StringRight', 'StringMid', 'StringLen',
    'StringReplace', 'StringGetPos',
    'StringLower', 'StringUpper',
    'StringTrimLeft', 'StringTrimRight',
    'EnvAdd', 'EnvSub', 'EnvMult', 'EnvDiv',
    'SetEnv', 'Transform'
)

# Build command regex: match line starting with any of these commands followed by
# a delimiter (comma, space, or end-of-line)
$commandPattern = '^(' + ($V1_COMMANDS -join '|') + ')(\s|,|$)'

# Func("...") pattern
$funcPattern = '\bFunc\s*\(\s*"'

# %var% legacy dereferencing pattern
# In AHK v1: %var% is used for variable dereferencing
# In AHK v2: obj.%name% is VALID dynamic property access — not a v1 pattern
# In AHK v2: %varRef% is VALID VarRef dereferencing — not a v1 pattern
# We also exclude %A_*% built-in variables (valid in #Include directives)
# Strategy: match %word% only when NOT preceded by a dot (which indicates v2
# dynamic property syntax) and when NOT a built-in %A_*% variable.
$legacyVarPattern = '(?<!\.)%(\w+)%'
$builtinVarExclude = '^A_'

# === Helpers ===

function Clean-Line {
    param([string]$line)

    # Remove full-line comments
    if ($line -match '^\s*;') { return '' }

    # Remove end-of-line comments (semicolon preceded by whitespace)
    $cleaned = $line -replace '\s;.*$', ''

    # Remove quoted strings to avoid false matches inside string literals
    $cleaned = $cleaned -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace "'[^']*'", "''"

    return $cleaned
}

# === Resolve source directory ===

if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

# === Scan ===

$files = @(Get-ChildItem -Path $SourceDir -Recurse -Filter '*.ahk')
$issues = @()

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $inBlockComment = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $rawLine = $lines[$i]
        $lineNum = $i + 1

        # Handle block comments (/* ... */)
        if ($inBlockComment) {
            if ($rawLine -match '\*/') {
                $inBlockComment = $false
            }
            continue
        }
        if ($rawLine -match '^\s*/\*') {
            $inBlockComment = $true
            continue
        }

        $cleaned = Clean-Line $rawLine
        if ([string]::IsNullOrWhiteSpace($cleaned)) { continue }

        # --- Check 1: Func("Name") ---
        if ($cleaned -match $funcPattern) {
            $issues += [PSCustomObject]@{
                File    = $file.FullName
                Line    = $lineNum
                Pattern = 'Func("Name")'
                Text    = $rawLine.TrimStart()
            }
        }

        # --- Check 2: %var% legacy dereferencing ---
        # Matches %word% NOT preceded by dot. Excludes %A_*% built-ins.
        $varMatches = [regex]::Matches($cleaned, $legacyVarPattern)
        foreach ($m in $varMatches) {
            # Group 1 is the variable name inside the percent signs
            $varName = $m.Groups[1].Value
            # Exclude %A_*% built-in variables (valid in #Include directives)
            if ($varName -match $builtinVarExclude) { continue }
            # Exclude VarRef dereference: %var% in "x is VarRef ? %var% : y" is valid v2
            if ($rawLine -match 'VarRef') { continue }
            $issues += [PSCustomObject]@{
                File    = $file.FullName
                Line    = $lineNum
                Pattern = '%var%'
                Text    = $rawLine.TrimStart()
            }
            # Only report once per line for this pattern
            break
        }

        # --- Check 3: Legacy v1 command syntax ---
        $trimmed = $cleaned.TrimStart()
        if ($trimmed -match $commandPattern) {
            $issues += [PSCustomObject]@{
                File    = $file.FullName
                Line    = $lineNum
                Pattern = 'v1 command'
                Text    = $rawLine.TrimStart()
            }
        }
    }
}

$totalSw.Stop()

# === Report ===

$timingLine = "  Timing: total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $($files.Count) files scanned, $($issues.Count) issue(s)"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) AHK v1 pattern(s) detected." -ForegroundColor Red
    Write-Host "  These patterns are not valid in AHK v2 and should be replaced." -ForegroundColor Red

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        # Show relative path from SourceDir for readability
        $relPath = $group.Name
        if ($relPath.StartsWith($SourceDir)) {
            $relPath = $relPath.Substring($SourceDir.Length).TrimStart('\', '/')
        }
        Write-Host "`n    $relPath`:" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line) [$($issue.Pattern)]: $($issue.Text)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: No AHK v1 patterns detected" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
