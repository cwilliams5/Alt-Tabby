# query_instrumentation.ps1 - Profiler instrumentation coverage map
#
# Scans MainProcess files (src/gui, src/core, src/shared) for functions
# and reports which have Profiler.Enter() instrumentation.
#
# Usage:
#   powershell -File tools/query_instrumentation.ps1              # summary table
#   powershell -File tools/query_instrumentation.ps1 -Full        # all functions with status
#   powershell -File tools/query_instrumentation.ps1 -Missing     # uninstrumented only
#   powershell -File tools/query_instrumentation.ps1 -Export      # markdown to stdout
#   powershell -File tools/query_instrumentation.ps1 -Save        # write to temp/INSTRUMENTATION_MAP.md

param(
    [switch]$Full,
    [switch]$Missing,
    [switch]$Export,
    [switch]$Save
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_query_helpers.ps1"

# --- Locate project root ---
$scriptDir = $PSScriptRoot
$projectRoot = (Resolve-Path "$scriptDir\..").Path
$srcDir = Join-Path $projectRoot "src"

# MainProcess scope: gui/, core/, shared/ (exclude lib/)
$scopeDirs = @("gui", "core", "shared")

# --- Scan all files ---
$allFunctions = [System.Collections.ArrayList]::new()

foreach ($dir in $scopeDirs) {
    $dirPath = Join-Path $srcDir $dir
    if (-not (Test-Path $dirPath)) { continue }

    $files = Get-ChildItem -Path $dirPath -Filter "*.ahk" -File
    foreach ($file in $files) {
        $lines = [System.IO.File]::ReadAllLines($file.FullName)
        $relPath = $file.FullName.Replace("$projectRoot\", '')

        $depth = 0
        $inFunc = $false
        $funcDepth = -1
        $currentFunc = $null
        $currentFuncLines = [System.Collections.ArrayList]::new()

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $cleaned = Clean-Line $lines[$i]
            if ($cleaned -eq '') {
                if ($inFunc) { [void]$currentFuncLines.Add($lines[$i]) }
                continue
            }

            $depthBefore = $depth

            # Function definition at file scope
            if (-not $inFunc -and $depthBefore -eq 0 -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
                $fname = $Matches[1]
                if (-not $AHK_KEYWORDS_SET.Contains($fname) -and $cleaned.Contains('{')) {
                    $isPrivate = $fname.StartsWith('_')
                    $currentFunc = [PSCustomObject]@{
                        Name = $fname
                        File = $relPath
                        Dir = $dir
                        Line = ($i + 1)
                        Private = $isPrivate
                        Instrumented = $false
                    }
                    $inFunc = $true
                    $funcDepth = $depthBefore
                }
            }

            if ($inFunc) {
                # Check for Profiler.Enter
                if ($lines[$i] -match 'Profiler\.Enter\(') {
                    $currentFunc.Instrumented = $true
                }
            }

            $depth += ($cleaned.Length - $cleaned.Replace('{','').Length) - ($cleaned.Length - $cleaned.Replace('}','').Length)
            if ($depth -lt 0) { $depth = 0 }

            if ($inFunc -and $depth -le $funcDepth) {
                $inFunc = $false
                $funcDepth = -1
                [void]$allFunctions.Add($currentFunc)
                $currentFunc = $null
            }
        }
    }
}

# --- Classify ---
$totalFuncs = $allFunctions.Count
$instrumented = @($allFunctions | Where-Object { $_.Instrumented })
$notInstrumented = @($allFunctions | Where-Object { -not $_.Instrumented })

# Group by file
$byFile = $allFunctions | Group-Object -Property File | Sort-Object Name

# --- Output ---
$outputLines = [System.Collections.ArrayList]::new()

function Out {
    param([string]$text = "")
    [void]$outputLines.Add($text)
    if (-not $Export -and -not $Save) {
        Write-Host $text
    }
}

function OutColor {
    param([string]$text, [string]$color = "White")
    [void]$outputLines.Add($text)
    if (-not $Export -and -not $Save) {
        Write-Host $text -ForegroundColor $color
    }
}

# Header
Out ""
OutColor "  Profiler Instrumentation Map" "White"
OutColor "  ============================" "DarkGray"
Out ""
OutColor "  Scope: src/gui/, src/core/, src/shared/" "DarkGray"
OutColor "  Total functions: $totalFuncs | Instrumented: $($instrumented.Count) ($([math]::Round($instrumented.Count / $totalFuncs * 100, 1))%) | Missing: $($notInstrumented.Count)" "Cyan"
Out ""

# Summary mode (default): per-file counts
if (-not $Full -and -not $Missing) {
    OutColor "  File                                    Total  Instr  Missing" "Yellow"
    OutColor ("  " + ("-" * 64)) "DarkGray"

    foreach ($group in $byFile) {
        $fileInstr = @($group.Group | Where-Object { $_.Instrumented }).Count
        $fileMissing = $group.Group.Count - $fileInstr
        $fileName = $group.Name
        # Truncate long paths
        if ($fileName.Length -gt 40) {
            $fileName = "..." + $fileName.Substring($fileName.Length - 37)
        }
        $padded = $fileName.PadRight(40)
        $bar = ""
        if ($fileInstr -gt 0 -and $fileMissing -gt 0) {
            $bar = "  $padded $($group.Group.Count.ToString().PadLeft(5))  $($fileInstr.ToString().PadLeft(5))  $($fileMissing.ToString().PadLeft(7))"
            OutColor $bar "White"
        } elseif ($fileInstr -gt 0) {
            $bar = "  $padded $($group.Group.Count.ToString().PadLeft(5))  $($fileInstr.ToString().PadLeft(5))  $($fileMissing.ToString().PadLeft(7))"
            OutColor $bar "Green"
        } else {
            $bar = "  $padded $($group.Group.Count.ToString().PadLeft(5))  $($fileInstr.ToString().PadLeft(5))  $($fileMissing.ToString().PadLeft(7))"
            OutColor $bar "DarkGray"
        }
    }
    Out ""
    if (-not $Export -and -not $Save) {
        OutColor "  Use -Full for all functions, -Missing for uninstrumented only, -Save to write temp/INSTRUMENTATION_MAP.md" "DarkGray"
        Out ""
    }
}

# Full or Missing mode: per-function detail
if ($Full -or $Missing) {
    foreach ($group in $byFile) {
        $funcsToShow = if ($Missing) {
            @($group.Group | Where-Object { -not $_.Instrumented })
        } else {
            @($group.Group)
        }

        if ($funcsToShow.Count -eq 0) { continue }

        OutColor "  $($group.Name)" "Yellow"

        foreach ($func in ($funcsToShow | Sort-Object { $_.Line })) {
            $vis = if ($func.Private) { "private" } else { "PUBLIC" }
            $status = if ($func.Instrumented) { "[PROFILED]" } else { "          " }
            $lineNum = "L$($func.Line)"

            if ($func.Instrumented) {
                OutColor "    $status $($func.Name) ($vis, $lineNum)" "Green"
            } else {
                OutColor "    $status $($func.Name) ($vis, $lineNum)" "DarkGray"
            }
        }
        Out ""
    }

    # Instrumented summary list
    if ($Full) {
        OutColor "  -- Instrumented Functions --" "Green"
        foreach ($f in ($instrumented | Sort-Object { $_.File + $_.Name })) {
            $shortFile = Split-Path $f.File -Leaf
            OutColor "    $($f.Name) (${shortFile}:$($f.Line))" "Green"
        }
        Out ""
    }
}

# Export / Save
if ($Export -or $Save) {
    $mdLines = [System.Collections.ArrayList]::new()
    [void]$mdLines.Add("# Profiler Instrumentation Map")
    [void]$mdLines.Add("")
    [void]$mdLines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$mdLines.Add("Scope: ``src/gui/``, ``src/core/``, ``src/shared/``")
    [void]$mdLines.Add("")
    [void]$mdLines.Add("**Total: $totalFuncs functions | Instrumented: $($instrumented.Count) ($([math]::Round($instrumented.Count / $totalFuncs * 100, 1))%) | Missing: $($notInstrumented.Count)**")
    [void]$mdLines.Add("")
    [void]$mdLines.Add("## Summary by File")
    [void]$mdLines.Add("")
    [void]$mdLines.Add("| File | Total | Instrumented | Missing |")
    [void]$mdLines.Add("|------|-------|-------------|---------|")

    foreach ($group in $byFile) {
        $fileInstr = @($group.Group | Where-Object { $_.Instrumented }).Count
        $fileMissing = $group.Group.Count - $fileInstr
        [void]$mdLines.Add("| ``$($group.Name)`` | $($group.Group.Count) | $fileInstr | $fileMissing |")
    }

    [void]$mdLines.Add("")
    [void]$mdLines.Add("## Instrumented Functions")
    [void]$mdLines.Add("")
    foreach ($f in ($instrumented | Sort-Object { $_.File + $_.Name })) {
        [void]$mdLines.Add("- ``$($f.Name)`` ($($f.File):$($f.Line))")
    }

    [void]$mdLines.Add("")
    [void]$mdLines.Add("## Uninstrumented Functions by File")
    [void]$mdLines.Add("")
    foreach ($group in $byFile) {
        $uninstr = @($group.Group | Where-Object { -not $_.Instrumented })
        if ($uninstr.Count -eq 0) { continue }

        [void]$mdLines.Add("### ``$($group.Name)``")
        [void]$mdLines.Add("")
        foreach ($f in ($uninstr | Sort-Object { $_.Line })) {
            $vis = if ($f.Private) { "private" } else { "**public**" }
            [void]$mdLines.Add("- ``$($f.Name)`` ($vis, L$($f.Line))")
        }
        [void]$mdLines.Add("")
    }

    $mdContent = $mdLines -join "`n"

    if ($Save) {
        $tempDir = Join-Path $projectRoot "temp"
        if (-not (Test-Path $tempDir)) {
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        }
        $outPath = Join-Path $tempDir "INSTRUMENTATION_MAP.md"
        [System.IO.File]::WriteAllText($outPath, $mdContent)
        Write-Host ""
        Write-Host "  Saved to: $outPath" -ForegroundColor Green
        Write-Host ""
    }

    if ($Export) {
        Write-Output $mdContent
    }
}
