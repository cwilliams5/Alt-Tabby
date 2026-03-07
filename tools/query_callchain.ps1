# query_callchain.ps1 - Call graph traversal from a function
#
# Shows what a function calls (forward) or what calls it (reverse),
# to a configurable depth. Replaces the pattern of chaining 4-6
# query_function.ps1 calls to manually trace a code path.
#
# Detects both direct calls and indirect references:
#   FuncName()              Direct call
#   SetTimer(FuncName, ...) Timer callback
#   OnMessage(0x..., Fn)    Message handler
#   OnEvent("...", Fn)      Event handler
#   .OnEvent("...", Fn)     GUI event handler
#
# Usage:
#   powershell -File tools/query_callchain.ps1 <funcName>
#   powershell -File tools/query_callchain.ps1 GUI_Repaint -Depth 3
#   powershell -File tools/query_callchain.ps1 GUI_Repaint -Reverse
#   powershell -File tools/query_callchain.ps1 GUI_Repaint -Reverse -Depth 1

param(
    [Parameter(Position=0)][string]$FuncName,
    [int]$Depth = 2,
    [switch]$Reverse,
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

. "$PSScriptRoot\_query_helpers.ps1"

if (-not $FuncName) {
    Write-Host "  Usage: query_callchain.ps1 <funcName> [-Depth N] [-Reverse]" -ForegroundColor Yellow
    Write-Host "  Examples:" -ForegroundColor DarkGray
    Write-Host "    query_callchain.ps1 GUI_Repaint              Forward calls (depth 2)" -ForegroundColor DarkGray
    Write-Host "    query_callchain.ps1 GUI_Repaint -Depth 3     Forward calls (depth 3)" -ForegroundColor DarkGray
    Write-Host "    query_callchain.ps1 GUI_Repaint -Reverse     Who calls this function" -ForegroundColor DarkGray
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

# === Collect source files (include lib/ — query tool reports all callers) ===
$srcFiles = Get-AhkSourceFiles $SourceDir -IncludeLib

# ============================================================
# Pass 1: Build function registry
# ============================================================
$pass1Sw = [System.Diagnostics.Stopwatch]::StartNew()

# funcRegistry: lowercase name -> @{ Name; File; RelPath; Line }
$funcRegistry = @{}
# fileCache: filePath -> string[] (lazy-split lines)
$fileCache = @{}

foreach ($file in $srcFiles) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $lines = Split-Lines $text
    $fileCache[$file.FullName] = $lines
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $depth = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        # Function definition at file scope (depth 0)
        if ($depth -eq 0) {
            $m = $script:_rxFuncDef.Match($cleaned)
            if ($m.Success) {
                $fname = $m.Groups[1].Value
                $fkey = $fname.ToLower()
                if (-not $AHK_KEYWORDS_SET.Contains($fkey) -and $cleaned.Contains('{')) {
                    if (-not $funcRegistry.ContainsKey($fkey)) {
                        $funcRegistry[$fkey] = @{
                            Name    = $fname
                            File    = $file.FullName
                            RelPath = $relPath
                            Line    = ($i + 1)
                        }
                    }
                }
            }
        }

        $depth += ($cleaned.Length - $cleaned.Replace('{','').Length) - ($cleaned.Length - $cleaned.Replace('}','').Length)
        if ($depth -lt 0) { $depth = 0 }
    }
}

# Build lookup set for fast matching
$funcNameSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($key in $funcRegistry.Keys) {
    [void]$funcNameSet.Add($key)
}

$pass1Sw.Stop()

# Check root function exists
$rootKey = $FuncName.ToLower()
if (-not $funcRegistry.ContainsKey($rootKey)) {
    Write-Host "  Function not found: $FuncName" -ForegroundColor Red

    # Suggest close matches
    $suggestions = @()
    foreach ($key in $funcRegistry.Keys) {
        if ($key.Contains($rootKey) -or $rootKey.Contains($key)) {
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

# ============================================================
# Pass 2: Build call graph (adjacency list)
# ============================================================
$pass2Sw = [System.Diagnostics.Stopwatch]::StartNew()

# callGraph: lowercase caller -> ArrayList of lowercase callee names
$callGraph = @{}

# Reference pattern: function name followed by ( — catches direct calls
$rxCallRef = [regex]::new('(?<![.\w])([a-zA-Z_]\w+)(?=\s*\()', 'Compiled')
# Callback patterns: function names passed as references (no trailing parenthesis)
# SetTimer(FuncRef, ...), OnMessage(msg, FuncRef), .OnEvent("ev", FuncRef)
$hasCallbackKeyword = $false

foreach ($file in $srcFiles) {
    $lines = $fileCache[$file.FullName]

    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $curFuncKey = ""
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        # Track function boundaries
        if (-not $inFunc -and $depth -eq 0) {
            $m = $script:_rxFuncDef.Match($cleaned)
            if ($m.Success) {
                $fname = $m.Groups[1].Value
                $fkey = $fname.ToLower()
                if (-not $AHK_KEYWORDS_SET.Contains($fkey) -and $cleaned.Contains('{')) {
                    $inFunc = $true
                    $funcDepth = $depth
                    $curFuncKey = $fkey
                    $seen.Clear()

                    if (-not $callGraph.ContainsKey($curFuncKey)) {
                        $callGraph[$curFuncKey] = [System.Collections.ArrayList]::new()
                    }
                }
            }
        }

        $depth += ($cleaned.Length - $cleaned.Replace('{','').Length) - ($cleaned.Length - $cleaned.Replace('}','').Length)
        if ($depth -lt 0) { $depth = 0 }

        if ($inFunc -and $depth -le $funcDepth) {
            $inFunc = $false
            $funcDepth = -1
        }

        # Only scan inside function bodies
        if (-not $inFunc) { continue }

        # Find direct calls: FuncName(
        $callMatches = $rxCallRef.Matches($cleaned)
        foreach ($cm in $callMatches) {
            $calledName = $cm.Groups[1].Value
            $calledKey = $calledName.ToLower()

            # Skip self, keywords, builtins, unknown functions
            if ($calledKey -eq $curFuncKey) { continue }
            if ($AHK_KEYWORDS_SET.Contains($calledKey)) { continue }
            if ($AHK_BUILTINS_SET.Contains($calledKey)) { continue }
            if (-not $funcNameSet.Contains($calledKey)) { continue }
            if ($seen.Contains($calledKey)) { continue }

            [void]$seen.Add($calledKey)
            [void]$callGraph[$curFuncKey].Add($calledKey)
        }

        # Callback references: on lines with SetTimer/OnMessage/OnEvent, also
        # match word tokens that are known functions without trailing (
        # This catches function refs like SetTimer(MyFunc, 1000) and OnMessage(0x312, _Handler)
        $hasCallbackKeyword = $cleaned.Contains('SetTimer') -or $cleaned.Contains('OnMessage') -or $cleaned.Contains('OnEvent')
        if ($hasCallbackKeyword) {
            $wordMatches = $script:_rxWord.Matches($cleaned)
            foreach ($wm in $wordMatches) {
                $calledKey = $wm.Value.ToLower()
                if ($calledKey -eq $curFuncKey) { continue }
                if ($AHK_KEYWORDS_SET.Contains($calledKey)) { continue }
                if (-not $funcNameSet.Contains($calledKey)) { continue }
                if ($seen.Contains($calledKey)) { continue }
                [void]$seen.Add($calledKey)
                [void]$callGraph[$curFuncKey].Add($calledKey)
            }
        }
    }
}

$pass2Sw.Stop()

# Build reverse graph if needed
$reverseGraph = @{}
if ($Reverse) {
    foreach ($callerKey in $callGraph.Keys) {
        foreach ($calleeKey in $callGraph[$callerKey]) {
            if (-not $reverseGraph.ContainsKey($calleeKey)) {
                $reverseGraph[$calleeKey] = [System.Collections.ArrayList]::new()
            }
            if (-not $reverseGraph[$calleeKey].Contains($callerKey)) {
                [void]$reverseGraph[$calleeKey].Add($callerKey)
            }
        }
    }
}

# ============================================================
# Pass 3: BFS traversal from root
# ============================================================
$graph = if ($Reverse) { $reverseGraph } else { $callGraph }
$rootDef = $funcRegistry[$rootKey]

# BFS with depth tracking
$visited = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
[void]$visited.Add($rootKey)

# Tree structure: list of @{ Key; Depth; IsAlreadyShown }
$treeNodes = [System.Collections.ArrayList]::new()

# Queue: @{ Key; Depth }
$queue = [System.Collections.Queue]::new()

# Seed with root's children
if ($graph.ContainsKey($rootKey)) {
    foreach ($childKey in ($graph[$rootKey] | Sort-Object)) {
        $queue.Enqueue(@{ Key = $childKey; Depth = 0 })
    }
}

$uniqueCount = 0
$maxDepthReached = 0

while ($queue.Count -gt 0) {
    $item = $queue.Dequeue()
    $key = $item.Key
    $d = $item.Depth

    if ($visited.Contains($key)) {
        [void]$treeNodes.Add(@{ Key = $key; Depth = $d; IsAlreadyShown = $true })
        continue
    }

    [void]$visited.Add($key)
    $uniqueCount++
    if ($d -gt $maxDepthReached) { $maxDepthReached = $d }
    [void]$treeNodes.Add(@{ Key = $key; Depth = $d; IsAlreadyShown = $false })

    # Enqueue children if not at max depth
    if ($d -lt $Depth -and $graph.ContainsKey($key)) {
        foreach ($childKey in ($graph[$key] | Sort-Object)) {
            $queue.Enqueue(@{ Key = $childKey; Depth = ($d + 1) })
        }
    }
}

$totalSw.Stop()

# ============================================================
# Output
# ============================================================
Write-Host ""
Write-Host "  $($rootDef.Name)  ($($rootDef.RelPath):$($rootDef.Line))" -ForegroundColor White
$dirLabel = if ($Reverse) { "called by" } else { "calls" }
Write-Host "    ${dirLabel}:" -ForegroundColor DarkGray

if ($treeNodes.Count -eq 0) {
    $noResultMsg = if ($Reverse) { "(no callers found)" } else { "(no calls to project functions)" }
    Write-Host "      $noResultMsg" -ForegroundColor DarkGray
} else {
    foreach ($node in $treeNodes) {
        $indent = "      " + ("  " * $node.Depth)
        $def = $funcRegistry[$node.Key]
        $name = $def.Name
        $loc = "$($def.RelPath):$($def.Line)"

        if ($node.IsAlreadyShown) {
            $label = if ($node.Key -eq $rootKey) { "(recursive)" } else { "(already shown)" }
            Write-Host "${indent}${name}" -ForegroundColor DarkGray -NoNewline
            Write-Host "  $label" -ForegroundColor DarkGray
        } else {
            # Pad name to align locations
            $padded = $name.PadRight(28)
            Write-Host "${indent}${padded}" -ForegroundColor White -NoNewline
            Write-Host " $loc" -ForegroundColor Cyan
        }
    }
}

Write-Host ""
$depthLabel = $maxDepthReached + 1
Write-Host "  $depthLabel level(s), $uniqueCount unique function(s)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Completed in $($totalSw.ElapsedMilliseconds)ms (pass1: $($pass1Sw.ElapsedMilliseconds)ms, pass2: $($pass2Sw.ElapsedMilliseconds)ms)" -ForegroundColor Cyan
