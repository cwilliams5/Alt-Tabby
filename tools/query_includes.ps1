# query_includes.ps1 - #Include dependency query
#
# Shows which files include a given module, or the full include tree.
#
# Usage:
#   powershell -File tools/query_includes.ps1                 (full include tree)
#   powershell -File tools/query_includes.ps1 window_list     (who includes this file?)
#   powershell -File tools/query_includes.ps1 window_list.ahk (same, with extension)

param(
    [Parameter(Position=0)]
    [string]$Target
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_query_helpers.ps1"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcDir = Join-Path $projectRoot "src"

if (-not (Test-Path $srcDir)) {
    Write-Host "  ERROR: Cannot find $srcDir" -ForegroundColor Red
    exit 1
}

# === Parse all #Include directives across all .ahk files ===
# Returns: array of { Source, Target, Optional, LineNum }
# Source/Target are relative paths from project root (e.g., src\gui\gui_main.ahk)

$allFiles = Get-AhkSourceFiles $srcDir -IncludeLib

# Build a filename-to-relpath lookup for all .ahk files
$fileIndex = @{}
foreach ($f in $allFiles) {
    $relPath = $f.FullName.Replace("$projectRoot\", '')
    $fileIndex[$f.Name.ToLower()] = $relPath
}

# Parse includes
$includes = [System.Collections.ArrayList]::new()  # { Source, Target, Optional, LineNum }

foreach ($file in $allFiles) {
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $currentDir = $file.DirectoryName

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if (-not $line.StartsWith('#Include')) { continue }

        # Strip inline comments
        $commentIdx = $line.IndexOf(' ;')
        if ($commentIdx -gt 0) { $line = $line.Substring(0, $commentIdx).Trim() }

        $optional = $false

        # Match: #Include *i <path>  (optional include)
        if ($line -match '^#Include\s+\*i\s+(.+)$') {
            $path = $Matches[1].Trim()
            $optional = $true
        }
        # Match: #Include <path>
        elseif ($line -match '^#Include\s+(.+)$') {
            $path = $Matches[1].Trim()
        }
        else { continue }

        # Resolve %A_ScriptDir% and %A_LineFile% variables
        $resolved = $path
        $resolved = $resolved -replace '%A_ScriptDir%', $file.DirectoryName
        $resolved = $resolved -replace '%A_LineFile%', $file.FullName

        # Resolve to absolute path
        if (-not [System.IO.Path]::IsPathRooted($resolved)) {
            $resolved = Join-Path $currentDir $resolved
        }
        $resolved = [System.IO.Path]::GetFullPath($resolved)

        # Directory change: #Include %A_ScriptDir%\gui\
        if ($resolved.EndsWith('\') -or (Test-Path $resolved -PathType Container -ErrorAction SilentlyContinue)) {
            $currentDir = $resolved.TrimEnd('\')
            continue
        }

        # File include — resolve relative path
        $targetRelPath = $resolved.Replace("$projectRoot\", '')

        [void]$includes.Add(@{
            Source   = $relPath
            Target   = $targetRelPath
            Optional = $optional
            LineNum  = ($i + 1)
        })
    }
}

# === Build forward and reverse maps ===
# Forward: source → targets[]
# Reverse: target → sources[]

$forwardMap = @{}
$reverseMap = @{}

foreach ($inc in $includes) {
    $src = $inc.Source
    $tgt = $inc.Target

    if (-not $forwardMap.ContainsKey($src)) { $forwardMap[$src] = [System.Collections.ArrayList]::new() }
    [void]$forwardMap[$src].Add($inc)

    if (-not $reverseMap.ContainsKey($tgt)) { $reverseMap[$tgt] = [System.Collections.ArrayList]::new() }
    [void]$reverseMap[$tgt].Add($inc)
}

# === No-arg mode: full include tree from entry points ===
if (-not $Target) {
    # Find entry points: files that are NOT included by anyone
    $allSources = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($forwardMap.Keys), [System.StringComparer]::OrdinalIgnoreCase)
    $allTargets = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($reverseMap.Keys), [System.StringComparer]::OrdinalIgnoreCase)

    $entryPoints = [System.Collections.ArrayList]::new()
    foreach ($src in $allSources) {
        if (-not $allTargets.Contains($src)) {
            [void]$entryPoints.Add($src)
        }
    }
    $entryPoints.Sort()

    Write-Host ""
    Write-Host "  Include Tree ($($includes.Count) directives across $($allFiles.Count) files)" -ForegroundColor White
    Write-Host ""

    function Show-Tree {
        param([string]$File, [string]$Indent, [System.Collections.Generic.HashSet[string]]$Visited)
        if ($Visited.Contains($File)) {
            Write-Host "${Indent}(circular) $File" -ForegroundColor DarkYellow
            return
        }
        [void]$Visited.Add($File)

        if (-not $forwardMap.ContainsKey($File)) { return }
        $children = $forwardMap[$File] | Sort-Object { $_.LineNum }
        foreach ($child in $children) {
            $marker = if ($child.Optional) { "*" } else { "" }
            $tgt = $child.Target
            $hasChildren = $forwardMap.ContainsKey($tgt)
            $color = if ($hasChildren) { "Cyan" } else { "Green" }
            Write-Host "${Indent}${marker}$tgt" -ForegroundColor $color
            if ($hasChildren) {
                Show-Tree $tgt "${Indent}  " $Visited
            }
        }
        [void]$Visited.Remove($File)
    }

    foreach ($entry in $entryPoints) {
        Write-Host "  $entry" -ForegroundColor White
        $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Show-Tree $entry "    " $visited
        Write-Host ""
    }

    Write-Host "  Legend: " -NoNewline -ForegroundColor DarkGray
    Write-Host "white" -NoNewline -ForegroundColor White
    Write-Host "=entry point  " -NoNewline -ForegroundColor DarkGray
    Write-Host "cyan" -NoNewline -ForegroundColor Cyan
    Write-Host "=has children  " -NoNewline -ForegroundColor DarkGray
    Write-Host "green" -NoNewline -ForegroundColor Green
    Write-Host "=leaf  " -NoNewline -ForegroundColor DarkGray
    Write-Host "*=optional" -ForegroundColor DarkGray

    $elapsed = $sw.ElapsedMilliseconds
    Write-Host "  Completed in ${elapsed}ms" -ForegroundColor DarkGray
    exit 0
}

# === Target mode: who includes this file? ===

# Normalize target: add .ahk if missing
$search = $Target
if (-not $search.EndsWith('.ahk')) { $search = "$search.ahk" }
$searchLower = $search.ToLower()

# Find matching files (by filename or partial path)
$matches = [System.Collections.ArrayList]::new()
foreach ($tgt in $reverseMap.Keys) {
    $tgtLower = $tgt.ToLower()
    if ($tgtLower.EndsWith("\$searchLower") -or $tgtLower -eq $searchLower -or
        [System.IO.Path]::GetFileName($tgtLower) -eq $searchLower) {
        [void]$matches.Add($tgt)
    }
}

# Also check files that exist but have no includers (leaf files or entry points)
if ($matches.Count -eq 0) {
    foreach ($name in $fileIndex.Keys) {
        if ($name -eq $searchLower) {
            $relPath = $fileIndex[$name]
            [void]$matches.Add($relPath)
        }
    }
}

if ($matches.Count -eq 0) {
    Write-Host "`n  No file matching '$Target' found in the codebase" -ForegroundColor Red
    Write-Host ""; exit 1
}
if ($matches.Count -gt 1) {
    Write-Host "`n  Ambiguous: '$Target' matches $($matches.Count) files:" -ForegroundColor Yellow
    foreach ($m in ($matches | Sort-Object)) { Write-Host "    $m" -ForegroundColor Cyan }
    Write-Host "`n  Use a more specific path (e.g., shared\$search)" -ForegroundColor DarkGray
    Write-Host ""; exit 1
}

$targetFile = $matches[0]

Write-Host ""
Write-Host "  $targetFile" -ForegroundColor White
Write-Host ""

# Direct includers
if ($reverseMap.ContainsKey($targetFile)) {
    $includers = @($reverseMap[$targetFile] | Sort-Object { $_.Source }, { $_.LineNum })
    Write-Host "  included by ($($includers.Count)):" -ForegroundColor Cyan
    $maxLocLen = 10
    foreach ($inc in $includers) {
        $len = "$($inc.Source):$($inc.LineNum)".Length
        if ($len -gt $maxLocLen) { $maxLocLen = $len }
    }
    foreach ($inc in $includers) {
        $loc = "$($inc.Source):$($inc.LineNum)".PadRight($maxLocLen + 2)
        $marker = if ($inc.Optional) { " (optional)" } else { "" }
        Write-Host "    $loc$marker" -ForegroundColor Green
    }
} else {
    Write-Host "  included by: (none - entry point or orphan)" -ForegroundColor DarkGray
}
Write-Host ""

# What this file includes (forward)
if ($forwardMap.ContainsKey($targetFile)) {
    $children = @($forwardMap[$targetFile] | Sort-Object { $_.LineNum })
    Write-Host "  includes ($($children.Count)):" -ForegroundColor Cyan
    $maxLocLen = 10
    foreach ($child in $children) {
        $len = "$($child.Target)".Length
        if ($len -gt $maxLocLen) { $maxLocLen = $len }
    }
    foreach ($child in $children) {
        $tgt = $child.Target.PadRight($maxLocLen + 2)
        $marker = if ($child.Optional) { " (optional)" } else { "" }
        Write-Host "    ${tgt}line $($child.LineNum)$marker" -ForegroundColor Green
    }
} else {
    Write-Host "  includes: (none - leaf file)" -ForegroundColor DarkGray
}
Write-Host ""

# Transitive reverse: who ultimately reaches this file?
$transitiveIncluders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$queue = [System.Collections.Queue]::new()
$queue.Enqueue($targetFile)
while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    if ($reverseMap.ContainsKey($current)) {
        foreach ($inc in $reverseMap[$current]) {
            if ($transitiveIncluders.Add($inc.Source)) {
                $queue.Enqueue($inc.Source)
            }
        }
    }
}

if ($transitiveIncluders.Count -gt 0) {
    # Find entry points in the transitive set
    $entryRoots = [System.Collections.ArrayList]::new()
    foreach ($t in $transitiveIncluders) {
        if (-not $reverseMap.ContainsKey($t)) {
            [void]$entryRoots.Add($t)
        }
    }
    if ($entryRoots.Count -gt 0) {
        $entryRoots.Sort()
        Write-Host "  entry points that reach this file:" -ForegroundColor Cyan
        foreach ($e in $entryRoots) {
            Write-Host "    $e" -ForegroundColor Green
        }
        Write-Host ""
    }
}

$elapsed = $sw.ElapsedMilliseconds
Write-Host "  Completed in ${elapsed}ms" -ForegroundColor DarkGray
