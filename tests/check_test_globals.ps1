# check_test_globals.ps1 - Verify test include chains provide all globals needed by production code
#
# Catches: Test file includes production code that uses a global constant/variable,
# but the test's #Include chain doesn't include the file that defines it.
# At runtime the global is declared but never assigned, causing VarUnset errors.
#
# Algorithm:
# 1. Collect all file-scope `global X := value` definitions from src/ (known globals)
# 2. For each test entry point (tests/*.ahk with #Requires):
#    a. Recursively trace #Include to build complete file tree
#    b. Collect all `global X := value` from the tree (available globals)
#    c. For each src/ file in the tree, find function-level `global X` declarations
#    d. Flag X if it exists in known globals but not in available globals
#
# Usage: powershell -File tests\check_test_globals.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = missing globals found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$MIN_GLOBAL_NAME_LENGTH = 2
$AHK_BUILTINS = @('true', 'false', 'unset', 'this', 'super')
$AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)

# === Helpers ===

function Clean-Line {
    param([string]$line)
    $cleaned = $line -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace "'[^']*'", "''"
    $cleaned = $cleaned -replace '\s;.*$', ''
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

# === Core Functions ===

function Get-FileScopeGlobalDefs {
    # Extract file-scope `global X := value` definitions from a file.
    # Returns hashtable: name -> $true
    param([string]$filePath)

    $defs = @{}
    if (-not (Test-Path $filePath)) { return $defs }

    $lines = [System.IO.File]::ReadAllLines($filePath)
    $depth = 0
    $inFunc = $false
    $funcDepth = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        $braces = Count-Braces $cleaned

        # Detect function/method start
        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1].ToLower()
            if ($fname -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                $inFunc = $true
                $funcDepth = $depth
            }
        }

        $depth += $braces[0] - $braces[1]

        if ($inFunc -and $depth -le $funcDepth) {
            $inFunc = $false
            $funcDepth = -1
        }

        # Collect file-scope globals with := (definitions, not bare declarations)
        if (-not $inFunc -and $cleaned -match '^\s*global\s+(.+)') {
            $declPart = $Matches[1]
            foreach ($name in (Extract-GlobalNames $declPart)) {
                $escapedName = [regex]::Escape($name)
                if ($declPart -match "\b$escapedName\s*:=") {
                    $defs[$name] = $true
                }
            }
        }
    }
    return $defs
}

function Get-FunctionGlobalUsage {
    # Extract function-level `global X` declarations from a file.
    # Returns array of objects with Name, FuncName, Line properties.
    param([string]$filePath)

    $usages = [System.Collections.ArrayList]::new()
    if (-not (Test-Path $filePath)) { return $usages }

    $lines = [System.IO.File]::ReadAllLines($filePath)
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""
    $funcGlobals = @{}  # Deduplicate within a function

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        $braces = Count-Braces $cleaned

        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if ($fname.ToLower() -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcDepth = $depth
                $funcGlobals = @{}
            }
        }

        $depth += $braces[0] - $braces[1]

        if ($inFunc) {
            if ($cleaned -match '^\s*global\s+(.+)') {
                foreach ($name in (Extract-GlobalNames $Matches[1])) {
                    if (-not $funcGlobals.ContainsKey($name)) {
                        $funcGlobals[$name] = $true
                        [void]$usages.Add([PSCustomObject]@{
                            Name     = $name
                            FuncName = $funcName
                            Line     = $i + 1
                        })
                    }
                }
            }

            if ($depth -le $funcDepth) {
                $inFunc = $false
                $funcDepth = -1
            }
        }
    }
    return $usages
}

function Resolve-AhkInclude {
    # Resolve an #Include directive to an absolute file path.
    # Returns $null if the path can't be resolved or file doesn't exist.
    param(
        [string]$rawLine,
        [string]$currentFileDir,
        [string]$scriptDir
    )

    $path = $rawLine.Trim()

    # Strip #Include and optional *i prefix
    $path = $path -replace '^\s*#Include\s+', ''
    $path = $path -replace '^\*i\s+', ''

    # Strip surrounding quotes
    $path = $path.Trim('"', "'")

    # Expand %A_ScriptDir%
    $path = $path -replace '%A_ScriptDir%', $scriptDir

    # Resolve relative paths against the including file's directory
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Join-Path $currentFileDir $path
    }

    # Normalize
    try {
        $path = [System.IO.Path]::GetFullPath($path)
    } catch {
        return $null
    }

    if (Test-Path $path) { return $path }
    return $null
}

function Build-IncludeTree {
    # Recursively trace #Include directives from an entry file.
    # Returns array of absolute file paths (entry file + all includes).
    param(
        [string]$entryFile,
        [string]$scriptDir
    )

    $visited = @{}
    $queue = [System.Collections.Queue]::new()
    $tree = [System.Collections.ArrayList]::new()

    $entryFull = [System.IO.Path]::GetFullPath($entryFile)
    $queue.Enqueue($entryFull)
    $visited[$entryFull.ToLower()] = $true
    [void]$tree.Add($entryFull)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not (Test-Path $current)) { continue }

        $currentDir = [System.IO.Path]::GetDirectoryName($current)
        $lines = [System.IO.File]::ReadAllLines($current)

        foreach ($line in $lines) {
            if ($line -match '^\s*#Include\s+') {
                $resolved = Resolve-AhkInclude $line $currentDir $scriptDir
                if ($resolved) {
                    $key = $resolved.ToLower()
                    if (-not $visited.ContainsKey($key)) {
                        $visited[$key] = $true
                        [void]$tree.Add($resolved)
                        $queue.Enqueue($resolved)
                    }
                }
            }
        }
    }

    return $tree
}

# === Resolve directories ===

if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$projectRoot = (Resolve-Path "$SourceDir\..").Path
$testsDir = Join-Path $projectRoot "tests"

if (-not (Test-Path $testsDir)) {
    Write-Host "  PASS: No tests directory found - skipping" -ForegroundColor Green
    exit 0
}

$srcDirNorm = [System.IO.Path]::GetFullPath($SourceDir).ToLower()

# === Pass 1: Collect all file-scope global definitions from src/ ===

$srcFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse)
$knownGlobals = @{}  # name -> relative path where defined

foreach ($file in $srcFiles) {
    $defs = Get-FileScopeGlobalDefs $file.FullName
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    foreach ($name in $defs.Keys) {
        if (-not $knownGlobals.ContainsKey($name)) {
            $knownGlobals[$name] = $relPath
        }
    }
}

# === Pass 2: Find test entry points ===
# Entry points are .ahk files in tests/ with a #Requires directive (standalone scripts).
# Files with "; check_test_globals: skip" in the first 10 lines are excluded.

$testFiles = @(Get-ChildItem -Path $testsDir -Filter "*.ahk" -File)
$entryPoints = [System.Collections.ArrayList]::new()
$skipped = 0

foreach ($tf in $testFiles) {
    $firstLines = @([System.IO.File]::ReadAllLines($tf.FullName) | Select-Object -First 10)
    $hasRequires = $false
    $hasSkip = $false
    foreach ($line in $firstLines) {
        if ($line -match '^\s*#Requires\s+AutoHotkey') { $hasRequires = $true }
        if ($line -match ';\s*check_test_globals:\s*skip') { $hasSkip = $true }
    }
    if ($hasRequires -and -not $hasSkip) {
        [void]$entryPoints.Add($tf)
    } elseif ($hasRequires -and $hasSkip) {
        $skipped++
    }
}

if ($entryPoints.Count -eq 0) {
    Write-Host "  PASS: No test entry points found" -ForegroundColor Green
    exit 0
}

# === Pass 3: Check each entry point's include tree ===

$issues = [System.Collections.ArrayList]::new()

foreach ($entry in $entryPoints) {
    $scriptDir = $entry.DirectoryName
    $tree = Build-IncludeTree $entry.FullName $scriptDir

    # Collect all globals DEFINED (with :=) in the tree
    $availableGlobals = @{}
    foreach ($file in $tree) {
        $defs = Get-FileScopeGlobalDefs $file
        foreach ($name in $defs.Keys) {
            $availableGlobals[$name] = $true
        }
    }

    # For each src/ file in the tree, check function-level global usage
    $relEntry = $entry.FullName.Replace("$projectRoot\", '')
    foreach ($file in $tree) {
        $fileLower = $file.ToLower()
        if (-not $fileLower.StartsWith($srcDirNorm)) { continue }

        $usages = Get-FunctionGlobalUsage $file
        $relFile = $file.Replace("$projectRoot\", '')

        foreach ($usage in $usages) {
            $name = $usage.Name
            # Flag only if: exists in src/ universe AND missing from this tree
            if ($knownGlobals.ContainsKey($name) -and -not $availableGlobals.ContainsKey($name)) {
                [void]$issues.Add([PSCustomObject]@{
                    TestEntry = $relEntry
                    SrcFile   = $relFile
                    Line      = $usage.Line
                    FuncName  = $usage.FuncName
                    Global    = $name
                    DefinedIn = $knownGlobals[$name]
                })
            }
        }
    }
}

$sw.Stop()

# === Report ===

# Deduplicate: same global missing from same entry point (may appear in multiple functions)
$deduped = $issues | Sort-Object TestEntry, Global -Unique

if ($deduped.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($deduped.Count) global(s) missing from test include chains." -ForegroundColor Red
    Write-Host "  Production code uses globals not available in the test's #Include tree." -ForegroundColor Red
    Write-Host "  Fix: add 'global <name> := <value>' to the test file, or #Include the file that defines it." -ForegroundColor Yellow

    $grouped = $deduped | Group-Object TestEntry
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host "`n    Test: $($group.Name)" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object SrcFile, Line) {
            Write-Host "      $($issue.SrcFile):$($issue.Line) - $($issue.FuncName)() needs '$($issue.Global)'" -ForegroundColor Red
            Write-Host "        (defined in $($issue.DefinedIn))" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  Scanned: $($entryPoints.Count) entry point(s), $($knownGlobals.Count) known globals, $($sw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: All test include chains provide required globals ($($entryPoints.Count) entry point(s), $($knownGlobals.Count) known globals)" -ForegroundColor Green
    exit 0
}
