# check_global_ownership.ps1 - Static analysis for global variable ownership
#
# Enforces that global variables are only mutated by authorized files.
# Reduces cross-file coupling and creates trustable invariants about which
# files can modify which state — enabling faster, safer development.
#
# Ownership model:
#   IMPLICIT: The file that declares a global at file scope is the sole
#             authorized writer. Covers 94% of globals with zero config.
#   EXPLICIT: Cross-boundary mutations are listed in a central manifest
#             file with their authorized writers. Only ~6% of globals need this.
#
# Manifest format (ownership.manifest):
#   # Comments start with #
#   gGUI_State: gui_state, gui_input
#   gGUI_Sel: gui_state, gui_input, gui_store, gui_workspace
#   cfg: config_loader, launcher_main, launcher_tray, ...
#
#   File names are basenames without extension or path. The declaring file
#   is always implicitly authorized — no need to list it.
#
# Discovery mode: Shows which globals are mutated in which files.
#   powershell -File tests/check_global_ownership.ps1 -Discover [-Verbose]
#
# Generate mode: Auto-generates manifest from current codebase state.
#   powershell -File tests/check_global_ownership.ps1 -Generate
#
# Query mode: Returns ownership info for a specific global.
#   powershell -File tests/check_global_ownership.ps1 -Query <globalName>
#
# Enforcement mode (default): Checks mutations against ownership rules.
#   powershell -File tests/check_global_ownership.ps1 [-SourceDir "path"]
#
# Mutation patterns detected:
#   gFoo := value             Direct assignment
#   gFoo += / -= / .= / *=    Compound assignment
#   gFoo++ / gFoo--            Increment/decrement
#   gFoo[key] := value         Index write
#   gFoo.Push() / .Pop() ...   Mutating container methods
#   gFoo.prop := value         Property write
#
# Exit codes: 0 = pass (or discovery/generate mode), 1 = violations found

param(
    [string]$SourceDir,
    [string]$Query,
    [switch]$Discover,
    [switch]$Generate,
    [switch]$Verbose
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
$manifestPath = Join-Path $projectRoot "ownership.manifest"

# === Collect source files (exclude lib/) ===
$srcFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

if ($Query) {
    # Query mode: silent startup, output only the answer
} elseif ($Discover) {
    Write-Host "  === Global Ownership Discovery ===" -ForegroundColor Cyan
    Write-Host "  Scanning $($srcFiles.Count) source files..." -ForegroundColor Cyan
} elseif ($Generate) {
    Write-Host "  Generating ownership manifest from $($srcFiles.Count) source files..." -ForegroundColor Cyan
} else {
    Write-Host "  Checking global ownership in $($srcFiles.Count) files..." -ForegroundColor Cyan
}

# === Helpers ===
function Clean-Line {
    param([string]$line)
    $cleaned = $line -replace '"[^"]*"', '""'
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

# Extract basename (without extension) from a relative path
function Get-Basename {
    param([string]$relPath)
    return [System.IO.Path]::GetFileNameWithoutExtension($relPath)
}

# AHK keywords (not function names)
$AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)
$AHK_BUILTINS = @('true', 'false', 'unset', 'this', 'super')

# Mutating method names (Maps, Arrays, Objects)
$MUTATING_METHODS = 'Push|Pop|Delete|InsertAt|RemoveAt|Set|Clear'

# ============================================================
# Pass 1: Collect file-scope globals
# ============================================================
$pass1Sw = [System.Diagnostics.Stopwatch]::StartNew()

# globalDecl: globalName -> @{ File; RelPath; Line }
$globalDecl = @{}
# fileCache: filePath -> string[]
$fileCache = @{}

foreach ($file in $srcFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $fileCache[$file.FullName] = $lines
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $depth = 0
    $inFunc = $false
    $funcDepth = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        $braces = Count-Braces $cleaned

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

        # File-scope global declarations (outside any function)
        if (-not $inFunc -and $cleaned -match '^\s*global\s+(.+)') {
            $declPart = $Matches[1]
            $stripped = Strip-Nested $declPart
            foreach ($part in $stripped -split ',') {
                $trimmed = $part.Trim()
                if ($trimmed -match '^(\w+)') {
                    $gName = $Matches[1]
                    if ($gName.Length -ge 2 -and $gName -notin $AHK_BUILTINS) {
                        if (-not $globalDecl.ContainsKey($gName)) {
                            $globalDecl[$gName] = @{
                                File    = $file.FullName
                                RelPath = $relPath
                                Line    = ($i + 1)
                            }
                        }
                    }
                }
            }
        }
    }
}

# Build lookup set for fast matching
$globalSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in $globalDecl.Keys) {
    [void]$globalSet.Add($name)
}

$pass1Sw.Stop()

# ============================================================
# Pass 2: Detect mutations in function bodies
# ============================================================
$pass2Sw = [System.Diagnostics.Stopwatch]::StartNew()

# Each entry: @{ Global; File; RelPath; Line; Code; Func }
$mutations = [System.Collections.ArrayList]::new()

foreach ($file in $srcFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        $braces = Count-Braces $cleaned

        if (-not $inFunc -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1].ToLower()
            if ($fname -notin $AHK_KEYWORDS -and $cleaned -match '\{') {
                $inFunc = $true
                $funcDepth = $depth
                $funcName = $Matches[1]
            }
        }

        $depth += $braces[0] - $braces[1]

        if ($inFunc -and $depth -le $funcDepth) {
            $inFunc = $false
            $funcDepth = -1
        }

        # Only scan inside function bodies
        if (-not $inFunc) { continue }

        # Find word tokens that match known globals, then test for mutation
        $wordMatches = [regex]::Matches($cleaned, '\b[a-zA-Z_]\w+\b')
        $seen = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($wm in $wordMatches) {
            $wName = $wm.Value
            if ($seen.Contains($wName)) { continue }
            [void]$seen.Add($wName)
            if (-not $globalSet.Contains($wName)) { continue }

            $escaped = [regex]::Escape($wName)
            $isMutation = $false

            # Pattern 1: Direct/compound assignment - gVar := / += / -= / .= / *= / /=
            # Negative lookbehind for \w and \. prevents matching property writes
            if ($cleaned -match "(?<![.\w])$escaped\s*[:+\-\*\/\.]+\=") {
                $isMutation = $true
            }

            # Pattern 2: Increment/decrement - gVar++ / gVar--
            if (-not $isMutation -and $cleaned -match "(?<![.\w])$escaped\s*(\+\+|--)") {
                $isMutation = $true
            }

            # Pattern 3: Index write - gVar[...] :=
            if (-not $isMutation -and $cleaned -match "(?<![.\w])$escaped\[.+?\]\s*[:+\-\*\/\.]+\=") {
                $isMutation = $true
            }

            # Pattern 4: Mutating methods - gVar.Push( / .Pop( / .Delete( etc.
            if (-not $isMutation -and $cleaned -match "\b$escaped\.($MUTATING_METHODS)\s*\(") {
                $isMutation = $true
            }

            # Pattern 5: Property write - gVar.propName :=
            if (-not $isMutation -and $cleaned -match "\b$escaped\.\w+\s*[:+\-\*\/\.]+\=") {
                $isMutation = $true
            }

            if ($isMutation) {
                [void]$mutations.Add(@{
                    Global  = $wName
                    File    = $file.FullName
                    RelPath = $relPath
                    Line    = ($i + 1)
                    Code    = $lines[$i].Trim()
                    Func    = $funcName
                })
            }
        }
    }
}

$pass2Sw.Stop()

# ============================================================
# Aggregate results
# ============================================================

# Group mutations by global -> file -> list of mutations
$byGlobal = @{}
foreach ($m in $mutations) {
    if (-not $byGlobal.ContainsKey($m.Global)) {
        $byGlobal[$m.Global] = @{}
    }
    if (-not $byGlobal[$m.Global].ContainsKey($m.File)) {
        $byGlobal[$m.Global][$m.File] = [System.Collections.ArrayList]::new()
    }
    [void]$byGlobal[$m.Global][$m.File].Add($m)
}

# Classify globals
$multiFileMutations = @{}
$singleFileMutations = @{}
$noMutations = @()

foreach ($gName in $globalDecl.Keys | Sort-Object) {
    if ($byGlobal.ContainsKey($gName)) {
        $fileCount = $byGlobal[$gName].Count
        if ($fileCount -gt 1) {
            $multiFileMutations[$gName] = $byGlobal[$gName]
        } else {
            $singleFileMutations[$gName] = $byGlobal[$gName]
        }
    } else {
        $noMutations += $gName
    }
}

# ============================================================
# Query Mode: Return ownership info for a specific global
# ============================================================
if ($Query) {
    $totalSw.Stop()

    if (-not $globalDecl.ContainsKey($Query)) {
        Write-Host "  Unknown global: $Query" -ForegroundColor Red
        Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
        exit 1
    }

    $decl = $globalDecl[$Query]
    $declBasename = Get-Basename $decl.RelPath

    Write-Host ""
    Write-Host "  $Query" -ForegroundColor White
    Write-Host "    declared: $($decl.RelPath):$($decl.Line)" -ForegroundColor Cyan

    # Collect writers
    if ($byGlobal.ContainsKey($Query)) {
        $writerNames = @()
        foreach ($filePath in ($byGlobal[$Query].Keys | Sort-Object)) {
            $basename = Get-Basename ($filePath.Replace("$projectRoot\", ''))
            $tag = if ($basename -eq $declBasename) { " (declares)" } else { "" }
            $writerNames += "$basename$tag"
        }
        Write-Host "    writers:  $($writerNames -join ', ')" -ForegroundColor DarkGray
    } else {
        Write-Host "    writers:  (none - constant or file-scope only)" -ForegroundColor DarkGray
    }

    # Check manifest
    $manifestLine = $null
    if (Test-Path $manifestPath) {
        $mLines = [System.IO.File]::ReadAllLines($manifestPath)
        for ($mi = 0; $mi -lt $mLines.Count; $mi++) {
            $mTrimmed = $mLines[$mi].Trim()
            if ($mTrimmed -match "^$([regex]::Escape($Query)):") {
                $manifestLine = $mi + 1
                break
            }
        }
    }

    if ($manifestLine) {
        Write-Host "    manifest: line $manifestLine" -ForegroundColor DarkGray
    } else {
        Write-Host "    manifest: (not listed - implicit ownership by declaring file)" -ForegroundColor DarkGray
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

    if ($multiFileMutations.Count -gt 0) {
        Write-Host "  --- COUPLING HOTSPOTS (mutated in 2+ files) ---" -ForegroundColor Yellow
        Write-Host ""

        $sorted = $multiFileMutations.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending
        foreach ($entry in $sorted) {
            $gName = $entry.Key
            $files = $entry.Value
            $decl = $globalDecl[$gName]
            $totalMuts = ($files.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum

            Write-Host "  $gName  " -ForegroundColor White -NoNewline
            Write-Host "($totalMuts mutations across $($files.Count) files)" -ForegroundColor DarkGray
            Write-Host "    declared: $($decl.RelPath):$($decl.Line)" -ForegroundColor DarkGray

            foreach ($filePath in ($files.Keys | Sort-Object)) {
                $fileMuts = $files[$filePath]
                $fileRel = $filePath.Replace("$projectRoot\", '')
                $isOwner = ($filePath -eq $decl.File)
                $ownerTag = if ($isOwner) { " (declares)" } else { "" }
                Write-Host "    $fileRel$ownerTag - $($fileMuts.Count) mutation(s)" -ForegroundColor $(if ($isOwner) { "Green" } else { "Red" })

                if ($Verbose) {
                    foreach ($m in $fileMuts) {
                        Write-Host "      L$($m.Line) [$($m.Func)] $($m.Code)" -ForegroundColor DarkGray
                    }
                }
            }
            Write-Host ""
        }
    }

    if ($singleFileMutations.Count -gt 0) {
        Write-Host "  --- CLEAN OWNERSHIP (mutated in 1 file only) ---" -ForegroundColor Green
        Write-Host ""
        foreach ($gName in ($singleFileMutations.Keys | Sort-Object)) {
            $files = $singleFileMutations[$gName]
            $filePath = @($files.Keys)[0]
            $fileRel = $filePath.Replace("$projectRoot\", '')
            $mutCount = $files[$filePath].Count
            $decl = $globalDecl[$gName]
            $sameFile = ($filePath -eq $decl.File)
            $tag = if ($sameFile) { "" } else { "  (declared elsewhere: $($decl.RelPath))" }
            Write-Host "  $gName - $fileRel ($mutCount mutation(s))$tag" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    if ($noMutations.Count -gt 0) {
        Write-Host "  --- CONSTANTS (no mutations in function bodies) ---" -ForegroundColor DarkCyan
        Write-Host "  $($noMutations.Count) globals with no function-body mutations (likely constants or set at file scope only)" -ForegroundColor DarkGray
        if ($Verbose) {
            foreach ($gName in $noMutations) {
                $decl = $globalDecl[$gName]
                Write-Host "    $gName - $($decl.RelPath):$($decl.Line)" -ForegroundColor DarkGray
            }
        }
        Write-Host ""
    }

    Write-Host "  --- SUMMARY ---" -ForegroundColor Cyan
    Write-Host "    Total globals:         $($globalDecl.Count)" -ForegroundColor White
    Write-Host "    Coupling hotspots:     $($multiFileMutations.Count)  (mutated in 2+ files)" -ForegroundColor $(if ($multiFileMutations.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host "    Clean ownership:       $($singleFileMutations.Count)  (mutated in 1 file)" -ForegroundColor Green
    Write-Host "    Constants/file-scope:  $($noMutations.Count)  (no function-body mutations)" -ForegroundColor DarkCyan
    Write-Host "    Total mutations found: $($mutations.Count)" -ForegroundColor White
    Write-Host ""
    $totalSw.Stop()
    Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms (pass1: $($pass1Sw.ElapsedMilliseconds)ms, pass2: $($pass2Sw.ElapsedMilliseconds)ms)" -ForegroundColor Cyan
    exit 0
}

# ============================================================
# Generate Mode: Create manifest from current state
# ============================================================
if ($Generate) {
    $lines = [System.Collections.ArrayList]::new()
    [void]$lines.Add("# ownership.manifest - Global variable write authorization")
    [void]$lines.Add("#")
    [void]$lines.Add("# Contract: If a global is NOT listed here, only the declaring file may")
    [void]$lines.Add("# mutate it. If it IS listed, only the declaring file plus the listed files")
    [void]$lines.Add("# may mutate it. Enforced by pre-gate (check_global_ownership.ps1).")
    [void]$lines.Add("#")
    [void]$lines.Add("# When the checker fails, either:")
    [void]$lines.Add("#   1. Add the file to this manifest (intentional cross-file mutation)")
    [void]$lines.Add("#   2. Move the mutation to the declaring file (keep coupling tight)")
    [void]$lines.Add("#")
    [void]$lines.Add("# Format: globalName: file1, file2, file3")
    [void]$lines.Add("#   Basenames without .ahk. The declaring file is always implicitly authorized.")
    [void]$lines.Add("#")
    [void]$lines.Add("# Maintenance:")
    [void]$lines.Add("#   Query a specific global: powershell -File tests/check_global_ownership.ps1 -Query <name>")
    [void]$lines.Add("#   Re-generate from scratch: powershell -File tests/check_global_ownership.ps1 -Generate")
    [void]$lines.Add("#   Discover full landscape:  powershell -File tests/check_global_ownership.ps1 -Discover")
    [void]$lines.Add("")

    # Collect all cross-boundary globals: multi-writer + cross-file single-writer
    $manifestEntries = @{}

    # Multi-writer globals (mutated in 2+ files)
    foreach ($entry in $multiFileMutations.GetEnumerator()) {
        $gName = $entry.Key
        $files = $entry.Value
        $decl = $globalDecl[$gName]
        $declBasename = Get-Basename $decl.RelPath

        $writerNames = @()
        foreach ($filePath in ($files.Keys | Sort-Object)) {
            $basename = Get-Basename ($filePath.Replace("$projectRoot\", ''))
            if ($basename -ne $declBasename) {
                $writerNames += $basename
            }
        }
        if ($writerNames.Count -gt 0) {
            $manifestEntries[$gName] = $writerNames
        }
    }

    # Cross-file single-writer globals (declared in A, mutated only in B)
    $crossFileSingle = 0
    foreach ($entry in $singleFileMutations.GetEnumerator()) {
        $gName = $entry.Key
        $files = $entry.Value
        $decl = $globalDecl[$gName]
        $declBasename = Get-Basename $decl.RelPath

        $mutatorPath = @($files.Keys)[0]
        $mutatorBasename = Get-Basename ($mutatorPath.Replace("$projectRoot\", ''))

        if ($mutatorBasename -ne $declBasename) {
            $manifestEntries[$gName] = @($mutatorBasename)
            $crossFileSingle++
        }
    }

    foreach ($gName in ($manifestEntries.Keys | Sort-Object)) {
        [void]$lines.Add("${gName}: $($manifestEntries[$gName] -join ', ')")
    }

    $content = $lines -join "`n"
    [System.IO.File]::WriteAllText($manifestPath, $content + "`n", [System.Text.Encoding]::UTF8)

    Write-Host "  Generated $manifestPath" -ForegroundColor Green
    Write-Host "  $($multiFileMutations.Count) multi-writer + $crossFileSingle cross-file single-writer = $($manifestEntries.Count) total entries" -ForegroundColor White
    $totalSw.Stop()
    Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 0
}

# ============================================================
# Enforcement Mode: Manifest + implicit ownership
# ============================================================

# Build allowed-to-mutate map: globalName -> HashSet<basename>
# Start with implicit: declaring file always authorized
$allowedWriters = @{}
foreach ($gName in $globalDecl.Keys) {
    $hs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    [void]$hs.Add((Get-Basename $globalDecl[$gName].RelPath))
    $allowedWriters[$gName] = $hs
}

# Load manifest (explicit multi-writer authorizations)
$manifestEntries = 0
if (Test-Path $manifestPath) {
    foreach ($line in [System.IO.File]::ReadAllLines($manifestPath)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

        # Parse "globalName: writer1, writer2, writer3"
        $colonIdx = $trimmed.IndexOf(':')
        if ($colonIdx -lt 1) { continue }

        $gName = $trimmed.Substring(0, $colonIdx).Trim()
        $writers = $trimmed.Substring($colonIdx + 1).Trim()

        if (-not $allowedWriters.ContainsKey($gName)) {
            # Manifest references unknown global - create entry
            $allowedWriters[$gName] = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
        }

        foreach ($writer in ($writers -split '[,\s]+' | Where-Object { $_ })) {
            [void]$allowedWriters[$gName].Add($writer.Trim())
        }
        $manifestEntries++
    }
}

if (-not (Test-Path $manifestPath)) {
    $totalSw.Stop()
    Write-Host "  No manifest found at: $manifestPath" -ForegroundColor DarkGray
    Write-Host "  Generate one: powershell -File tests/check_global_ownership.ps1 -Generate" -ForegroundColor DarkGray
    Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 0
}

# Check for violations
$violations = [System.Collections.ArrayList]::new()

foreach ($m in $mutations) {
    $gName = $m.Global
    if (-not $allowedWriters.ContainsKey($gName)) { continue }

    $mutatorBasename = Get-Basename $m.RelPath
    if (-not $allowedWriters[$gName].Contains($mutatorBasename)) {
        [void]$violations.Add($m)
    }
}

$totalSw.Stop()

if ($violations.Count -eq 0) {
    Write-Host "  All $($mutations.Count) mutations respect ownership ($($globalDecl.Count) globals, $manifestEntries manifest entries)" -ForegroundColor Green
    Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 0
}

# Group violations by file
$violByFile = @{}
foreach ($v in $violations) {
    if (-not $violByFile.ContainsKey($v.RelPath)) {
        $violByFile[$v.RelPath] = [System.Collections.ArrayList]::new()
    }
    [void]$violByFile[$v.RelPath].Add($v)
}

Write-Host ""
Write-Host "  OWNERSHIP VIOLATIONS ($($violations.Count)):" -ForegroundColor Red
Write-Host ""

foreach ($fileRel in ($violByFile.Keys | Sort-Object)) {
    $fileViols = $violByFile[$fileRel]
    Write-Host "  $fileRel" -ForegroundColor Yellow
    foreach ($v in $fileViols) {
        $ownerRel = $globalDecl[$v.Global].RelPath
        Write-Host "    L$($v.Line) [$($v.Func)] " -NoNewline -ForegroundColor White
        Write-Host "$($v.Global)" -NoNewline -ForegroundColor Red
        Write-Host " - declared in: $ownerRel" -ForegroundColor DarkGray
        Write-Host "      $($v.Code)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

$affectedGlobals = ($violations | ForEach-Object { $_.Global } | Sort-Object -Unique).Count
Write-Host "  $($violations.Count) violation(s) across $($violByFile.Count) file(s) affecting $affectedGlobals global(s)" -ForegroundColor Red
Write-Host "  Fix: add the writer to the global's entry in ownership.manifest" -ForegroundColor Yellow
Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
exit 1
