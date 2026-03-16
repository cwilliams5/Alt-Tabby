# query_events.ps1 - Flight recorder event type query
#
# Extracts event code definitions from gui_flight_recorder.ahk without
# loading the full 700+ line file into context.
#
# Usage:
#   powershell -File tools/query_events.ps1                  (list all event types)
#   powershell -File tools/query_events.ps1 focus             (fuzzy search by name)
#   powershell -File tools/query_events.ps1 50                (lookup by numeric code)
#   powershell -File tools/query_events.ps1 -Emitters         (show which functions emit each event)

param(
    [Parameter(Position=0)]
    [string]$Query,
    [switch]$Emitters
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_query_helpers.ps1"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcDir = Join-Path $projectRoot "src"
$frFile = Join-Path $srcDir "gui\gui_flight_recorder.ahk"

if (-not (Test-Path $frFile)) {
    Write-Host "  ERROR: Cannot find $frFile" -ForegroundColor Red
    exit 1
}

# === Parse event code definitions ===
$events = [System.Collections.ArrayList]::new()
$stateConstants = [System.Collections.ArrayList]::new()
$lines = [System.IO.File]::ReadAllLines($frFile)
$sectionComment = ""

$evRx = [regex]::new('^\s*global\s+(FR_EV_\w+)\s*:=\s*(\d+)\s*;\s*(.*)')
$stRx = [regex]::new('^\s*global\s+(FR_ST_\w+)\s*:=\s*(\d+)')
$secRx = [regex]::new(';\s*(\w[\w /]+)\((\d+)-(\d+)\)')

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]

    # Track section comments
    if ($line -match ';\s*=+\s*(.+?)\s*=+') {
        if ($Matches[1] -ne "EVENT CODES" -and $Matches[1] -ne "RING BUFFER" -and $Matches[1] -ne "INIT") {
            $sectionComment = $Matches[1]
        }
        continue
    }
    $secMatch = $secRx.Match($line)
    if ($secMatch.Success) {
        $sectionComment = $secMatch.Groups[1].Value.Trim()
        continue
    }

    # Parse event definitions
    $m = $evRx.Match($line)
    if ($m.Success) {
        $name = $m.Groups[1].Value
        $code = [int]$m.Groups[2].Value
        $comment = $m.Groups[3].Value.Trim()

        # Parse d1-d4 field descriptions from comment
        $fields = [System.Collections.ArrayList]::new()
        foreach ($fm in [regex]::Matches($comment, '(d[1-4])=(\S+(?:\s*\([^)]+\))?)')) {
            [void]$fields.Add(@{ Field = $fm.Groups[1].Value; Desc = $fm.Groups[2].Value })
        }
        # Also capture trailing text after last d= as context
        $context = $comment -replace 'd[1-4]=\S+(?:\s*\([^)]+\))?\s*', '' | ForEach-Object { $_.Trim() }
        if ($context -eq '—' -or $context.Length -lt 3) { $context = "" }

        [void]$events.Add(@{
            Name = $name; Code = $code; Comment = $comment
            Fields = $fields; Context = $context
            Section = $sectionComment; Line = ($i + 1)
        })
    }

    # Parse state constants (FR_ST_*)
    $sm = $stRx.Match($line)
    if ($sm.Success) {
        [void]$stateConstants.Add(@{ Name = $sm.Groups[1].Value; Value = [int]$sm.Groups[2].Value })
    }
}

if ($events.Count -eq 0) {
    Write-Host "  ERROR: No FR_EV_ constants found in $frFile" -ForegroundColor Red
    exit 1
}

# === Emitter scan helper (deferred for queries that won't display emitters) ===
$emitterMap = @{}
$emitterScanned = $false

function Scan-Emitters {
    if ($script:emitterScanned) { return }
    $script:emitterScanned = $true
    $allFiles = Get-AhkSourceFiles $srcDir
    foreach ($file in $allFiles) {
        $fileText = [System.IO.File]::ReadAllText($file.FullName)
        if ($fileText.IndexOf('FR_Record(', [StringComparison]::Ordinal) -lt 0 -and
            $fileText.IndexOf('FR_EV_', [StringComparison]::Ordinal) -lt 0) { continue }

        $fileLines = Split-Lines $fileText
        $relPath = $file.FullName.Replace("$projectRoot\", '')
        $funcBounds = Build-FuncBoundaryMap $fileLines

        for ($i = 0; $i -lt $fileLines.Count; $i++) {
            $fl = $fileLines[$i]
            if ($fl.IndexOf('FR_Record(') -lt 0) { continue }
            if ($fl -match 'FR_Record\(\s*(FR_EV_\w+)') {
                $evName = $Matches[1]
                $funcName = Find-EnclosingFunction $funcBounds $i
                $lineNum = $i + 1
                if (-not $script:emitterMap.ContainsKey($evName)) {
                    $script:emitterMap[$evName] = [System.Collections.ArrayList]::new()
                }
                [void]$script:emitterMap[$evName].Add(@{ File = $relPath; Line = $lineNum; Func = $funcName })
            }
        }
    }
}

# Eager scan when -Emitters flag is set
if ($Emitters.IsPresent) { Scan-Emitters }

# === Apply query filter ===
$filtered = $events
if ($Query) {
    $matches = [System.Collections.ArrayList]::new()
    # Try numeric code lookup first
    $numericCode = 0
    $isNumeric = [int]::TryParse($Query, [ref]$numericCode)
    if ($isNumeric) {
        foreach ($ev in $events) {
            if ($ev.Code -eq $numericCode) { [void]$matches.Add($ev) }
        }
    }
    if ($matches.Count -eq 0) {
        $qLower = $Query.ToLower()
        foreach ($ev in $events) {
            if ($ev.Name.ToLower().Contains($qLower) -or $ev.Comment.ToLower().Contains($qLower)) {
                [void]$matches.Add($ev)
            }
        }
    }
    $filtered = $matches
}

if ($filtered.Count -eq 0 -and $Query) {
    Write-Host "`n  No events matching '$Query'" -ForegroundColor Red
    Write-Host "  Total: $($events.Count) event types"
    Write-Host ""; exit 1
}

# Deferred emitter scan: only when detail mode will display them
if (-not $emitterScanned -and $Query -and $filtered.Count -le 5 -and $filtered.Count -gt 0) {
    Scan-Emitters
}

# === Output ===
if ($Query -and $filtered.Count -le 5) {
    # Detail mode
    foreach ($ev in $filtered) {
        Write-Host ""
        Write-Host "  $($ev.Name)  (code $($ev.Code))" -ForegroundColor White
        Write-Host "    section: $($ev.Section)" -ForegroundColor DarkGray
        Write-Host "    defined: gui_flight_recorder.ahk:$($ev.Line)" -ForegroundColor DarkGray
        if ($ev.Fields.Count -gt 0) {
            Write-Host "    fields:" -ForegroundColor Cyan
            foreach ($f in $ev.Fields) {
                Write-Host "      $($f.Field) = $($f.Desc)" -ForegroundColor Green
            }
        } else {
            Write-Host "    fields:  (none)" -ForegroundColor DarkGray
        }
        if ($ev.Context) {
            Write-Host "    note:    $($ev.Context)" -ForegroundColor DarkGray
        }
        # Show emitters
        $evEmits = $emitterMap[$ev.Name]
        if ($evEmits -and $evEmits.Count -gt 0) {
            Write-Host "    emitters:" -ForegroundColor Cyan
            foreach ($e in ($evEmits | Sort-Object { $_.File }, { $_.Line })) {
                Write-Host "      $($e.File):$($e.Line)  [$($e.Func)]" -ForegroundColor Green
            }
        } elseif ($Emitters) {
            Write-Host "    emitters: (none found)" -ForegroundColor DarkGray
        }
    }
} else {
    # Table mode — group by section
    Write-Host ""
    $title = if ($Query) { "Events matching '$Query'" } else { "Flight Recorder Event Types" }
    Write-Host "  $title ($($filtered.Count)):" -ForegroundColor White

    $currentSection = ""
    $maxNameLen = ($filtered | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    $maxCodeLen = ($filtered | ForEach-Object { "$($_.Code)".Length } | Measure-Object -Maximum).Maximum

    foreach ($ev in ($filtered | Sort-Object { $_.Code })) {
        if ($ev.Section -ne $currentSection) {
            $currentSection = $ev.Section
            Write-Host ""
            Write-Host "    ; $currentSection" -ForegroundColor DarkGray
        }
        $nameStr = $ev.Name.PadRight($maxNameLen + 2)
        $codeStr = "$($ev.Code)".PadLeft($maxCodeLen)
        $fieldStr = if ($ev.Fields.Count -gt 0) {
            ($ev.Fields | ForEach-Object { "$($_.Field)=$($_.Desc)" }) -join ' '
        } else { "" }

        Write-Host "    $codeStr  $nameStr $fieldStr" -ForegroundColor Cyan

        if ($Emitters) {
            $evEmits = $emitterMap[$ev.Name]
            if ($evEmits) {
                foreach ($e in ($evEmits | Sort-Object { $_.File })) {
                    Write-Host "          -> $($e.File):$($e.Line) [$($e.Func)]" -ForegroundColor DarkGray
                }
            }
        }
    }

    # State constants
    if (-not $Query -and $stateConstants.Count -gt 0) {
        Write-Host ""
        Write-Host "    ; State code constants (FR_EV_STATE d1)" -ForegroundColor DarkGray
        foreach ($sc in $stateConstants) {
            Write-Host "    $($sc.Value)  $($sc.Name)" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
$elapsed = $sw.ElapsedMilliseconds
Write-Host "  Total: $($events.Count) event types across $(@($filtered | ForEach-Object { $_.Section } | Select-Object -Unique).Count) sections" -ForegroundColor DarkGray
Write-Host "  Completed in ${elapsed}ms" -ForegroundColor DarkGray
