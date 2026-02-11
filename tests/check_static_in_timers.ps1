# check_static_in_timers.ps1 - Static analysis for AHK v2 static variables in timer callbacks
# Detects static variables used for state tracking inside timer callback functions.
# Static vars in timer callbacks can leak state if the timer is cancelled and restarted.
# Project rule: use tick-based timing (globals) instead of static counters.
#
# Exceptions: static Buffer() and static := 0 for DllCall marshal buffers are allowed,
# as these are persistent marshal buffers repopulated before each use (per project rules).
#
# Usage: powershell -File tests\check_static_in_timers.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = static-in-timer issues found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Helpers ===
function Clean-Line {
    param([string]$line)
    # Remove quoted strings to avoid false matches on content inside strings
    $cleaned = $line -replace '"[^"]*"', '""'
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
$files = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })
Write-Host "  Scanning $($files.Count) files for static variables in timer callbacks..." -ForegroundColor Cyan

# ============================================================
# Phase 1: Find all SetTimer targets (function names used as callbacks)
# ============================================================
$phase1Sw = [System.Diagnostics.Stopwatch]::StartNew()
$timerCallbacks = @{}  # functionName -> list of "relpath:lineNum" where SetTimer is called
$fileCache = @{}  # Cache file lines for reuse in Phase 2

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $fileCache[$file.FullName] = $lines
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        # Pattern: SetTimer(FuncName, ...) or SetTimer FuncName, ...
        # Must match a bare identifier (not a fat-arrow, not a string, not an object.prop)
        #
        # SetTimer(FuncName       - direct function reference
        # SetTimer FuncName       - command-style (rare in v2 but valid)
        # SetTimer(FuncName.Bind(  - bound function reference
        # SetTimer(ObjBindMethod(obj, "MethodName"  - object method binding

        # Direct function reference: SetTimer(FuncName  or  SetTimer FuncName
        # Excludes fat-arrow lambdas by requiring the first arg to be a bare identifier
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\s*[,\.\)]' -or
            $cleaned -match 'SetTimer\s+([A-Za-z_]\w+)\s*[,]') {
            $funcName = $Matches[1]
            # Skip built-in functions used as callbacks (e.g. ToolTip)
            if ($funcName -eq 'ToolTip') { continue }
            if (-not $timerCallbacks.ContainsKey($funcName)) {
                $timerCallbacks[$funcName] = [System.Collections.ArrayList]::new()
            }
            [void]$timerCallbacks[$funcName].Add("${relPath}:$($i + 1)")
        }

        # ObjBindMethod pattern: SetTimer(ObjBindMethod(obj, "MethodName"
        if ($cleaned -match 'SetTimer\(\s*ObjBindMethod\(\s*\w+\s*,\s*"(\w+)"') {
            $methodName = $Matches[1]
            if (-not $timerCallbacks.ContainsKey($methodName)) {
                $timerCallbacks[$methodName] = [System.Collections.ArrayList]::new()
            }
            [void]$timerCallbacks[$methodName].Add("${relPath}:$($i + 1)")
        }

        # .Bind() pattern: SetTimer(FuncName.Bind(
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\.Bind\(') {
            $funcName = $Matches[1]
            if (-not $timerCallbacks.ContainsKey($funcName)) {
                $timerCallbacks[$funcName] = [System.Collections.ArrayList]::new()
            }
            [void]$timerCallbacks[$funcName].Add("${relPath}:$($i + 1)")
        }
    }
}
$phase1Sw.Stop()

# ============================================================
# Phase 2: For each timer callback, find static variable declarations
# ============================================================
$phase2Sw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()
$AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)
$functionsScanned = 0

foreach ($file in $files) {
    $lines = $fileCache[$file.FullName]

    # Pre-filter: skip files without any timer callback function name
    if ($timerCallbacks.Count -gt 0) {
        $joined = [string]::Join("`n", $lines)
        $hasCallback = $false
        foreach ($cbName in $timerCallbacks.Keys) {
            if ($joined.IndexOf($cbName) -ge 0) { $hasCallback = $true; break }
        }
        if (-not $hasCallback) { continue }
    }

    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]

        # Detect function/method start
        if (-not $inFunc -and $cleaned -ne '' -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if ($fname.ToLower() -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcDepth = $depth
                $functionsScanned++
            }
        }

        $braces = Count-Braces $cleaned
        $depth += $braces[0] - $braces[1]

        if ($inFunc) {
            # Only inspect functions that are timer callbacks
            if ($timerCallbacks.ContainsKey($funcName) -and $cleaned -ne '') {
                # Check for static variable declarations
                if ($cleaned -match '^\s*static\s+(.+)') {
                    $staticContent = $Matches[1]
                    $rawLine = $lines[$i]

                    # Check for suppression comment on the raw (unstripped) line
                    if ($rawLine -match 'lint-ignore:\s*static-in-timer') {
                        # Suppressed, skip this line entirely
                    } else {
                        # Parse each variable in the static declaration
                        # Handle multi-var: static a, b := val, c := Func()
                        # Split by comma respecting nested parens/brackets
                        $parenDepth = 0
                        $parts = [System.Collections.ArrayList]::new()
                        $current = [System.Text.StringBuilder]::new()
                        foreach ($c in $staticContent.ToCharArray()) {
                            if ($c -eq '(' -or $c -eq '[') { $parenDepth++ }
                            elseif ($c -eq ')' -or $c -eq ']') { if ($parenDepth -gt 0) { $parenDepth-- } }
                            if ($c -eq ',' -and $parenDepth -eq 0) {
                                [void]$parts.Add($current.ToString())
                                $current = [System.Text.StringBuilder]::new()
                            } else {
                                [void]$current.Append($c)
                            }
                        }
                        [void]$parts.Add($current.ToString())

                        foreach ($part in $parts) {
                            $trimmed = $part.Trim()
                            if ($trimmed -match '^(\w+)(.*)$') {
                                $varName = $Matches[1]
                                $rest = $Matches[2].Trim()

                                # Exclusion: Buffer() allocations for DllCall marshalling
                                # Pattern: static buf := Buffer(
                                if ($rest -match '^:=\s*Buffer\(') { continue }

                                # Exclusion: static var := 0 (numeric zero init for DllCall marshal)
                                if ($rest -match '^:=\s*0\s*$') { continue }

                                # This is a flagged static variable in a timer callback
                                [void]$issues.Add([PSCustomObject]@{
                                    File         = $relPath
                                    Function     = $funcName
                                    Line         = ($i + 1)
                                    Variable     = $varName
                                    SetTimerRefs = $timerCallbacks[$funcName]
                                })
                            }
                        }
                    }
                }
            }

            # End of function
            if ($depth -le $funcDepth) {
                $inFunc = $false
                $funcDepth = -1
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
$statsLine  = "  Stats:  $($timerCallbacks.Count) timer callback(s), $functionsScanned function(s) scanned, $($files.Count) file(s)"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) static variable(s) in timer callback(s) found." -ForegroundColor Red
    Write-Host "  Static vars in timer callbacks can leak state if the timer is cancelled and restarted." -ForegroundColor Red
    Write-Host "  Fix: use tick-based timing with globals instead of static counters." -ForegroundColor Yellow
    Write-Host "  Suppress: add '; lint-ignore: static-in-timer' on the static declaration line." -ForegroundColor Yellow

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host ""
        Write-Host "    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line): $($issue.Function)() has static var '$($issue.Variable)'" -ForegroundColor Red
            foreach ($ref in $issue.SetTimerRefs) {
                Write-Host "        (SetTimer at $ref)" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: No static variables in timer callbacks" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
