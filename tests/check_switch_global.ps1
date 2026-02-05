# check_switch_global.ps1 - Static analysis for AHK v2 global declarations inside switch blocks
# Pre-gate test: runs before any AHK process launches.
# Catches `global` declarations inside switch/case blocks, which cause syntax errors in AHK v2.
#
# In AHK v2, globals must be declared at function scope, not inline in switch cases:
#   WRONG:  case "Foo": global Foo; return Foo
#   RIGHT:  global Foo  (at top of function, before the switch)
#
# Usage: powershell -File tests\check_switch_global.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = issues found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Helpers ===
function Clean-Line {
    param([string]$line)
    # Remove full-line comments first
    if ($line -match '^\s*;') { return '' }
    # Remove quoted strings to avoid false positives on "global" inside strings
    $cleaned = $line -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace "'[^']*'", "''"
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
$files = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })
Write-Host "  Scanning $($files.Count) files for global declarations inside switch blocks..." -ForegroundColor Cyan

# ============================================================
# Single-pass scan: track switch block depth and flag globals
# ============================================================
$scanSw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0

    # Stack of switch brace depths. When we detect a switch statement opening,
    # we push the brace depth at which its block starts. Any `global` found
    # while the current depth >= top-of-stack is inside a switch block.
    $switchDepthStack = [System.Collections.Generic.Stack[int]]::new()

    # Track whether we saw a `switch` keyword and are waiting for its opening brace.
    $pendingSwitch = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $cleaned = Clean-Line $raw

        if ($cleaned -eq '') { continue }

        # Detect switch statement: `switch` at statement position
        if ($cleaned -match '(?<![.\w])switch\b') {
            if ($cleaned -match '\{') {
                # Opening brace on same line as switch
                $pendingSwitch = $false
                $braces = Count-Braces $cleaned
                $newDepth = $depth + $braces[0] - $braces[1]
                # Content inside the switch is at depth+1 or deeper
                $switchDepthStack.Push($depth + 1)
                $depth = $newDepth
                continue
            } else {
                # No brace yet - switch opening brace will come on a subsequent line
                $pendingSwitch = $true
                $braces = Count-Braces $cleaned
                $depth += $braces[0] - $braces[1]
                continue
            }
        }

        # Count braces on this line
        $braces = Count-Braces $cleaned
        $opensOnLine = $braces[0]
        $closesOnLine = $braces[1]

        # If we're waiting for the switch's opening brace
        if ($pendingSwitch -and $opensOnLine -gt 0) {
            $pendingSwitch = $false
            # The switch block's inner depth is current depth + 1
            $switchDepthStack.Push($depth + 1)
        }

        # Check for `global` declaration while inside any switch block
        if ($switchDepthStack.Count -gt 0 -and $depth -ge $switchDepthStack.Peek()) {
            if ($cleaned -match '(?<![.\w])global\s+\w') {
                [void]$issues.Add([PSCustomObject]@{
                    File = $relPath
                    Line = $i + 1
                    Text = $raw.TrimEnd()
                })
            }
        }

        # Update depth
        $depth += $opensOnLine - $closesOnLine

        # Pop switch depths that we've exited (closing brace brought us below switch depth)
        while ($switchDepthStack.Count -gt 0 -and $depth -lt $switchDepthStack.Peek()) {
            [void]$switchDepthStack.Pop()
        }
    }
}
$scanSw.Stop()
$totalSw.Stop()

# ============================================================
# Report
# ============================================================
$timingLine = "  Timing: scan=$($scanSw.ElapsedMilliseconds)ms  total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $($files.Count) files scanned, $($issues.Count) issue(s) found"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) global declaration(s) inside switch blocks." -ForegroundColor Red
    Write-Host "  AHK v2 does not allow 'global' inside switch/case - declare at function scope instead." -ForegroundColor Yellow

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host "`n    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line): $($issue.Text.Trim())" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: No global declarations inside switch blocks" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
