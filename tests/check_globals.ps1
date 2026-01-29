# check_globals.ps1 - Static analysis for AHK v2 undeclared global references
# Pre-gate test: runs before any AHK process launches.
# Catches functions that use file-scope globals without a 'global' declaration,
# which silently become empty strings with #Warn VarUnset, Off.
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
    # Remove quoted strings to avoid false matches on variable names inside strings
    $cleaned = $line -replace '"[^"]*"', '""'
    # Remove end-of-line comments (semicolon preceded by whitespace)
    $cleaned = $cleaned -replace '\s;.*$', ''
    # Remove full-line comments
    if ($cleaned -match '^\s*;') { return '' }
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
$files = Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse
Write-Host "  Scanning $($files.Count) files for undeclared global references..." -ForegroundColor Cyan

# ============================================================
# Pass 1: Collect all file-scope global variable names
# ============================================================
$pass1Sw = [System.Diagnostics.Stopwatch]::StartNew()
$fileGlobals = @{}  # globalName -> "relpath:lineNum"

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
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
                if (-not $fileGlobals.ContainsKey($gName)) {
                    $fileGlobals[$gName] = "${relPath}:$($i + 1)"
                }
            }
        }
    }
}
$pass1Sw.Stop()

# ============================================================
# Pass 2: Check every function for undeclared global references
# ============================================================
$pass2Sw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()
$funcCount = 0

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
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
                # Extract all unique word tokens from the function body
                $allText = ($funcBodyLines | ForEach-Object { $_.Text }) -join " "
                $tokenSet = @{}
                foreach ($m in [regex]::Matches($allText, '\b([A-Za-z_]\w{1,})\b')) {
                    $tokenSet[$m.Groups[1].Value] = $true
                }

                # Check each known global
                foreach ($gName in $fileGlobals.Keys) {
                    if (-not $tokenSet.ContainsKey($gName)) { continue }
                    if ($funcDeclaredGlobals.ContainsKey($gName)) { continue }
                    if ($funcParams.ContainsKey($gName)) { continue }
                    if ($funcLocals.ContainsKey($gName)) { continue }

                    # Find first occurrence for line number
                    $escapedName = [regex]::Escape($gName)
                    $foundLine = $null
                    foreach ($bodyLine in $funcBodyLines) {
                        if ($bodyLine.Text -match "\b$escapedName\b" -and $bodyLine.Text -notmatch '^\s*(?:global|static|local)\s') {
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
                            Declared = $fileGlobals[$gName]
                        })
                    }
                }

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
$statsLine  = "  Stats:  $($fileGlobals.Count) globals, $funcCount functions, $($files.Count) files"

if ($issues.Count -gt 0) {
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
