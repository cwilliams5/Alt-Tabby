# query_impact.ps1 - Blast radius analysis for a function
#
# Shows everything that could be affected by changing a function:
# callers, globals it writes, who reads those globals, and optionally
# transitive callers. Combines what would require chaining
# query_function_visibility + query_global_ownership.
#
# Usage:
#   powershell -File tools/query_impact.ps1 <funcName>
#   powershell -File tools/query_impact.ps1 GUI_Repaint -Deep

param(
    [Parameter(Position=0)][string]$FuncName,
    [switch]$Deep,
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

. "$PSScriptRoot\_query_helpers.ps1"

if (-not $FuncName) {
    Write-Host "  Usage: query_impact.ps1 <funcName> [-Deep]" -ForegroundColor Yellow
    Write-Host "  Examples:" -ForegroundColor DarkGray
    Write-Host "    query_impact.ps1 GUI_Repaint          Callers + globals written + readers" -ForegroundColor DarkGray
    Write-Host "    query_impact.ps1 GUI_Repaint -Deep    Also show transitive callers" -ForegroundColor DarkGray
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

# === Collect source files (exclude lib/) ===
$srcFiles = Get-AhkSourceFiles $SourceDir

# ============================================================
# Step 1: Locate function definition + extract body
# ============================================================
$funcDef = $null
$funcBody = @()
$funcBodyStartIdx = -1
$funcFile = $null

# Also build function registry + file-scope globals for later steps
$funcRegistry = @{}
$globalDecl = @{}
$fileCache = @{}

$MUTATING_METHODS = 'Push|Pop|Delete|InsertAt|RemoveAt|Set|Clear'

foreach ($file in $srcFiles) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $lines = Split-Lines $text
    $fileCache[$file.FullName] = $lines
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $depth = 0
    $inFunc = $false
    $funcDepth = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        # Collect file-scope globals
        if (-not $inFunc -and $cleaned -match '^\s*global\s+(.+)') {
            $declPart = $Matches[1]
            $stripped = Strip-Nested $declPart
            foreach ($part in $stripped -split ',') {
                $trimmed = $part.Trim()
                if ($trimmed -match '^(\w+)') {
                    $gName = $Matches[1]
                    if ($gName.Length -ge 2 -and -not $AHK_BUILTINS_SET.Contains($gName)) {
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

        # Function definition at file scope
        if (-not $inFunc) {
            $m = $script:_rxFuncDef.Match($cleaned)
            if ($m.Success) {
                $fname = $m.Groups[1].Value
                $fkey = $fname.ToLower()
                if (-not $AHK_KEYWORDS_SET.Contains($fkey) -and $cleaned.Contains('{')) {
                    $inFunc = $true
                    $funcDepth = $depth

                    if (-not $funcRegistry.ContainsKey($fkey)) {
                        $funcRegistry[$fkey] = @{
                            Name    = $fname
                            File    = $file.FullName
                            RelPath = $relPath
                            Line    = ($i + 1)
                        }
                    }

                    # If this is our target function, start capturing body
                    if ($fkey -eq $FuncName.ToLower() -and -not $funcDef) {
                        $funcDef = $funcRegistry[$fkey]
                        $funcFile = $file.FullName
                        $funcBodyStartIdx = $i
                    }
                }
            }
        }

        $braceOpen = $cleaned.Length - $cleaned.Replace('{','').Length
        $braceClose = $cleaned.Length - $cleaned.Replace('}','').Length
        $depth += $braceOpen - $braceClose
        if ($depth -lt 0) { $depth = 0 }

        # Capture function body lines
        if ($funcBodyStartIdx -ge 0 -and $i -ge $funcBodyStartIdx -and $funcBody.Count -eq 0) {
            # We're inside the target function — keep going until depth drops
        }

        if ($inFunc -and $depth -le $funcDepth) {
            # If this was our target function, capture body
            if ($funcBodyStartIdx -ge 0 -and $funcBody.Count -eq 0 -and $file.FullName -eq $funcFile) {
                for ($bi = $funcBodyStartIdx; $bi -le $i; $bi++) {
                    $funcBody += $lines[$bi]
                }
            }
            $inFunc = $false
            $funcDepth = -1
        }
    }

    # Handle EOF without closing brace for target function
    if ($funcBodyStartIdx -ge 0 -and $funcBody.Count -eq 0 -and $file.FullName -eq $funcFile) {
        for ($bi = $funcBodyStartIdx; $bi -lt $lines.Count; $bi++) {
            $funcBody += $lines[$bi]
        }
    }
}

if (-not $funcDef) {
    Write-Host "  Function not found: $FuncName" -ForegroundColor Red
    # Suggest close matches
    $suggestions = @()
    $searchKey = $FuncName.ToLower()
    foreach ($key in $funcRegistry.Keys) {
        if ($key.Contains($searchKey) -or $searchKey.Contains($key)) {
            $suggestions += $funcRegistry[$key].Name
        }
    }
    if ($suggestions.Count -gt 0 -and $suggestions.Count -le 10) {
        Write-Host "  Did you mean:" -ForegroundColor Yellow
        foreach ($s in ($suggestions | Sort-Object)) {
            Write-Host "    $s" -ForegroundColor DarkGray
        }
    }
    exit 1
}

# Build lookup sets
$funcNameSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($key in $funcRegistry.Keys) { [void]$funcNameSet.Add($key) }

$globalSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in $globalDecl.Keys) { [void]$globalSet.Add($name) }

# ============================================================
# Step 2: Find direct callers
# ============================================================
$callers = [System.Collections.ArrayList]::new()
$escaped = [regex]::Escape($funcDef.Name)
$rxRef = [regex]::new("(?<![.\w])$escaped(?=\s*[\(,\)\s\.\[]|`$)", 'Compiled, IgnoreCase')

foreach ($file in $srcFiles) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    if ($text.IndexOf($funcDef.Name, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $bounds = Build-FuncBoundaryMap $lines

    for ($i = 0; $i -lt $lines.Count; $i++) {
        # Skip the definition line itself
        if ($file.FullName -eq $funcDef.File -and ($i + 1) -eq $funcDef.Line) { continue }

        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        if ($rxRef.IsMatch($cleaned)) {
            $enclosing = Find-EnclosingFunction $bounds $i
            [void]$callers.Add(@{
                RelPath = $relPath
                Line    = ($i + 1)
                Func    = $enclosing
            })
        }
    }
}

# ============================================================
# Step 3: Find globals written by this function
# ============================================================
$globalsWritten = [System.Collections.ArrayList]::new()
$globalsWrittenSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# First find which globals are declared in this function's scope
$funcGlobalDecls = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($bodyLine in $funcBody) {
    $cleaned = Clean-Line $bodyLine
    if ($cleaned -match '^\s*global\s+(.+)') {
        $declPart = $Matches[1]
        $stripped = Strip-Nested $declPart
        foreach ($part in $stripped -split ',') {
            $trimmed = $part.Trim()
            if ($trimmed -match '^(\w+)') {
                $gName = $Matches[1]
                if ($globalSet.Contains($gName)) {
                    [void]$funcGlobalDecls.Add($gName)
                }
            }
        }
    }
}

# Now scan for mutations of those globals
foreach ($gName in $funcGlobalDecls) {
    $e = [regex]::Escape($gName)
    $mutPatterns = @(
        [regex]::new("(?<![.\w])$e\s*[:+\-\*\/\.]+\="),
        [regex]::new("(?<![.\w])$e\s*(\+\+|--)"),
        [regex]::new("(?<![.\w])$e\[.+?\]\s*[:+\-\*\/\.]+\="),
        [regex]::new("\b$e\.($MUTATING_METHODS)\s*\("),
        [regex]::new("\b$e\.\w+\s*[:+\-\*\/\.]+\=")
    )

    foreach ($bodyLine in $funcBody) {
        $cleaned = Clean-Line $bodyLine
        if ($cleaned -eq '') { continue }

        $isMutation = $mutPatterns[0].IsMatch($cleaned) -or
                      $mutPatterns[1].IsMatch($cleaned) -or
                      $mutPatterns[2].IsMatch($cleaned) -or
                      $mutPatterns[3].IsMatch($cleaned) -or
                      $mutPatterns[4].IsMatch($cleaned)

        if ($isMutation -and -not $globalsWrittenSet.Contains($gName)) {
            [void]$globalsWrittenSet.Add($gName)
            [void]$globalsWritten.Add(@{
                Name    = $gName
                Decl    = $globalDecl[$gName]
            })
            break  # found at least one mutation, move to next global
        }
    }
}

# ============================================================
# Step 4: Find downstream readers of written globals
# ============================================================
$downstreamReaders = @{}  # globalName -> ArrayList of @{ RelPath; Func }

foreach ($gw in $globalsWritten) {
    $gName = $gw.Name
    $readers = [System.Collections.ArrayList]::new()
    $seenReaders = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($file in $srcFiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        if ($text.IndexOf($gName, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

        $lines = $fileCache[$file.FullName]
        $relPath = $file.FullName.Replace("$projectRoot\", '')
        $bounds = Build-FuncBoundaryMap $lines

        # Check if any function in this file declares global <gName>
        $inFunc = $false
        $funcDepth = -1
        $curFunc = ""
        $curFuncDeclaresGlobal = $false
        $depth = 0

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $cleaned = Clean-Line $lines[$i]
            if ($cleaned -eq '') { continue }

            if (-not $inFunc) {
                $fm = $script:_rxFuncDef.Match($cleaned)
                if ($fm.Success) {
                    $fn = $fm.Groups[1].Value
                    if (-not $AHK_KEYWORDS_SET.Contains($fn) -and $cleaned.Contains('{')) {
                        $inFunc = $true
                        $funcDepth = $depth
                        $curFunc = $fn
                        $curFuncDeclaresGlobal = $false
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

            # Check for global declaration inside function
            if ($cleaned -match '^\s*global\s+' -and $cleaned -match "(?<!\w)$([regex]::Escape($gName))(?!\w)") {
                $curFuncDeclaresGlobal = $true
            }

            # Check for read reference (non-mutation, non-declaration line)
            if ($curFuncDeclaresGlobal -and $cleaned -match "(?<![.\w])$([regex]::Escape($gName))(?!\w)") {
                $isGlobalDeclLine = $cleaned -match '^\s*global\s+'
                if (-not $isGlobalDeclLine) {
                    $readerKey = "${relPath}:${curFunc}"
                    if (-not $seenReaders.Contains($readerKey)) {
                        [void]$seenReaders.Add($readerKey)
                        [void]$readers.Add(@{
                            RelPath = $relPath
                            Func    = $curFunc
                        })
                    }
                }
            }
        }
    }

    if ($readers.Count -gt 0) {
        $downstreamReaders[$gName] = $readers
    }
}

# ============================================================
# Step 5 (if -Deep): Transitive callers
# ============================================================
$transCallers = [System.Collections.ArrayList]::new()

if ($Deep -and $callers.Count -gt 0) {
    # For each direct caller, find THEIR callers
    $directCallerFuncs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($c in $callers) {
        if ($c.Func -ne "(file scope)") {
            [void]$directCallerFuncs.Add($c.Func)
        }
    }

    $transCount = 0
    foreach ($callerFuncName in $directCallerFuncs) {
        if (-not $funcRegistry.ContainsKey($callerFuncName.ToLower())) { continue }
        $callerDef = $funcRegistry[$callerFuncName.ToLower()]
        $escapedCaller = [regex]::Escape($callerDef.Name)
        $rxCallerRef = [regex]::new("(?<![.\w])$escapedCaller(?=\s*[\(,\)\s\.\[]|`$)", 'IgnoreCase')

        foreach ($file in $srcFiles) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            if ($text.IndexOf($callerDef.Name, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

            $lines = $fileCache[$file.FullName]
            $relPath = $file.FullName.Replace("$projectRoot\", '')
            $bounds = Build-FuncBoundaryMap $lines

            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($file.FullName -eq $callerDef.File -and ($i + 1) -eq $callerDef.Line) { continue }

                $cleaned = Clean-Line $lines[$i]
                if ($cleaned -eq '') { continue }

                if ($rxCallerRef.IsMatch($cleaned)) {
                    $enclosing = Find-EnclosingFunction $bounds $i
                    [void]$transCallers.Add(@{
                        DirectCaller  = $callerDef.Name
                        DirectCallerRel = $callerDef.RelPath
                        TransCaller   = $enclosing
                        TransCallerRel = $relPath
                        Line          = ($i + 1)
                    })
                    $transCount++
                    if ($transCount -ge 20) { break }
                }
            }
            if ($transCount -ge 20) { break }
        }
        if ($transCount -ge 20) { break }
    }
}

$totalSw.Stop()

# ============================================================
# Output
# ============================================================
Write-Host ""
Write-Host "  $($funcDef.Name)  ($($funcDef.RelPath):$($funcDef.Line))" -ForegroundColor White

# Callers
Write-Host ""
if ($callers.Count -gt 0) {
    Write-Host "  callers ($($callers.Count)):" -ForegroundColor Green
    # Group by file
    $callersByFile = @{}
    foreach ($c in $callers) {
        if (-not $callersByFile.ContainsKey($c.RelPath)) {
            $callersByFile[$c.RelPath] = [System.Collections.ArrayList]::new()
        }
        [void]$callersByFile[$c.RelPath].Add($c)
    }
    foreach ($fileRel in ($callersByFile.Keys | Sort-Object)) {
        $fileParts = @()
        foreach ($c in $callersByFile[$fileRel]) {
            $fileParts += "$($c.Func) :$($c.Line)"
        }
        $basename = [System.IO.Path]::GetFileName($fileRel)
        Write-Host "    $($basename.PadRight(22)) $($fileParts -join ', ')" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  callers: no external callers (possibly entry point or callback)" -ForegroundColor DarkGray
}

# Globals written
Write-Host ""
if ($globalsWritten.Count -gt 0) {
    Write-Host "  globals written ($($globalsWritten.Count)):" -ForegroundColor Green
    foreach ($gw in ($globalsWritten | Sort-Object { $_.Name })) {
        $decl = $gw.Decl
        Write-Host "    $($gw.Name.PadRight(30)) declared $($decl.RelPath):$($decl.Line)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  globals written: no global side effects" -ForegroundColor DarkGray
}

# Downstream readers
if ($downstreamReaders.Count -gt 0) {
    Write-Host ""
    Write-Host "  downstream readers of written globals:" -ForegroundColor Green
    foreach ($gName in ($downstreamReaders.Keys | Sort-Object)) {
        $readers = $downstreamReaders[$gName]
        # Group by file basename
        $byFile = @{}
        foreach ($r in $readers) {
            $basename = [System.IO.Path]::GetFileName($r.RelPath)
            $base = [System.IO.Path]::GetFileNameWithoutExtension($r.RelPath)
            if (-not $byFile.ContainsKey($base)) { $byFile[$base] = 0 }
            $byFile[$base]++
        }
        $fileSummary = @()
        foreach ($base in ($byFile.Keys | Sort-Object)) {
            $count = $byFile[$base]
            $fileSummary += "$base ($count fn)"
        }
        Write-Host "    $($gName.PadRight(30)) $($fileSummary -join ', ')" -ForegroundColor DarkGray
    }
}

# Transitive callers
if ($Deep -and $transCallers.Count -gt 0) {
    Write-Host ""
    Write-Host "  transitive callers (depth 2):" -ForegroundColor Green
    foreach ($tc in $transCallers) {
        $tcRel = [System.IO.Path]::GetFileName($tc.TransCallerRel)
        Write-Host "    $($tc.DirectCaller) <- $($tc.TransCaller) ($tcRel`:$($tc.Line))" -ForegroundColor DarkGray
    }
    if ($transCallers.Count -ge 20) {
        Write-Host "    ... and more (capped at 20)" -ForegroundColor DarkGray
    }
}

# Blast radius summary
$affectedFiles = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$affectedFuncs = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

foreach ($c in $callers) {
    [void]$affectedFiles.Add($c.RelPath)
    [void]$affectedFuncs.Add($c.Func)
}
foreach ($gName in $downstreamReaders.Keys) {
    foreach ($r in $downstreamReaders[$gName]) {
        [void]$affectedFiles.Add($r.RelPath)
        [void]$affectedFuncs.Add($r.Func)
    }
}

Write-Host ""
Write-Host "  blast radius: $($affectedFiles.Count) file(s), $($affectedFuncs.Count) function(s)" -ForegroundColor White
Write-Host ""
Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
