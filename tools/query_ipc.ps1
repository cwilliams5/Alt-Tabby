# query_ipc.ps1 - IPC message flow query
#
# Shows who sends and who handles each IPC message type.
#
# Usage:
#   powershell -File tools/query_ipc.ps1                   (list all message types)
#   powershell -File tools/query_ipc.ps1 snapshot           (query by string value)
#   powershell -File tools/query_ipc.ps1 IPC_MSG_SNAPSHOT   (query by constant name)

param(
    [Parameter(Position=0)]
    [string]$Message
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcDir = Join-Path $projectRoot "src"
$constantsFile = Join-Path $srcDir "shared\ipc_constants.ahk"

if (-not (Test-Path $constantsFile)) {
    Write-Host "  ERROR: Cannot find $constantsFile" -ForegroundColor Red
    exit 1
}

# === Parse IPC message constants ===
$constants = [System.Collections.ArrayList]::new()
$constantLines = [System.IO.File]::ReadAllLines($constantsFile)
for ($i = 0; $i -lt $constantLines.Count; $i++) {
    if ($constantLines[$i] -match '^\s*global\s+(IPC_MSG_\w+)\s*:=\s*"(\w+)"') {
        [void]$constants.Add(@{ Name = $Matches[1]; Value = $Matches[2]; Line = ($i + 1) })
    }
}
if ($constants.Count -eq 0) {
    Write-Host "  ERROR: No IPC_MSG_ constants found" -ForegroundColor Red
    exit 1
}

# === No-arg mode: list all message types ===
if (-not $Message) {
    Write-Host ""
    Write-Host "  IPC Message Types ($($constants.Count)):" -ForegroundColor White
    Write-Host ""
    $maxValLen = ($constants | ForEach-Object { $_.Value.Length } | Measure-Object -Maximum).Maximum
    foreach ($c in $constants) {
        $padded = $c.Value.PadRight($maxValLen + 2)
        Write-Host "    $padded $($c.Name)" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "  Query: query_ipc.ps1 <message>     (string value or constant name)" -ForegroundColor DarkGray
    $elapsed = $sw.ElapsedMilliseconds
    Write-Host "  Completed in ${elapsed}ms" -ForegroundColor DarkGray
    exit 0
}

# === Resolve the queried message ===
$target = $null
$searchLower = $Message.ToLower()

# Exact match
foreach ($c in $constants) {
    if ($c.Name -eq $Message -or $c.Value -eq $Message) { $target = $c; break }
}
# Case-insensitive match
if (-not $target) {
    foreach ($c in $constants) {
        if ($c.Name.ToLower() -eq $searchLower -or $c.Value.ToLower() -eq $searchLower) { $target = $c; break }
    }
}
# Partial match
if (-not $target) {
    $partials = @($constants | Where-Object {
        $_.Name.ToLower().Contains($searchLower) -or $_.Value.ToLower().Contains($searchLower)
    })
    if ($partials.Count -eq 1) {
        $target = $partials[0]
    } elseif ($partials.Count -gt 1) {
        Write-Host "`n  Ambiguous message: '$Message' matches $($partials.Count) types:" -ForegroundColor Yellow
        foreach ($p in $partials) { Write-Host "    $($p.Value)  ($($p.Name))" -ForegroundColor Cyan }
        Write-Host ""; exit 1
    }
}
if (-not $target) {
    Write-Host "`n  Unknown message type: '$Message'" -ForegroundColor Red
    Write-Host "  Available types:" -ForegroundColor DarkGray
    foreach ($c in $constants) { Write-Host "    $($c.Value)  ($($c.Name))" -ForegroundColor DarkGray }
    Write-Host ""; exit 1
}

$constName = $target.Name
$constValue = $target.Value
$constLine = $target.Line
$ahkKeywords = @('if','else','while','for','loop','switch','case','catch','finally',
    'try','return','throw','not','and','or','is','in','contains','isset')

# Pre-compile hot-loop regex (avoids per-iteration string interpolation and regex cache lookups)
$constNameRx = [regex]::new("\b$constName\b")
$rawPatternRx = [regex]::new($rawPattern)
$constDeclRx = [regex]::new("^\s*global\s+$constName\b\s*:=")
$handleEqRx = [regex]::new("(?<!:)=\s*$constName\b")
$handleCaseRx = [regex]::new("case\s+$constName\b")
$handleNeqRx = [regex]::new("!=\s*$constName\b")
$sendTypeRx = [regex]::new("type:\s*$constName\b")
$sendBracketRx = [regex]::new("\[`"type`"\]\s*:=\s*$constName\b")
$sendJsonRx = [regex]::new("type`":\s*`".*\b$constName\b")
$sendQuoteRx = [regex]::new("'.*type.*\b$constName\b")
$sendTernaryRx = [regex]::new("\?\s*$constName\b")
$sendTailRx = [regex]::new(":\s*$constName\s*$")

# === Helper: build function boundary map for a file ===
function Build-FuncBounds {
    param([string[]]$Lines, [string[]]$Keywords)
    $bounds = [System.Collections.ArrayList]::new()
    for ($j = 0; $j -lt $Lines.Count; $j++) {
        if ($Lines[$j] -match '^(\w+)\s*\(') {
            $candidate = $Matches[1]
            if ($candidate.ToLower() -in $Keywords) { continue }
            $hasBody = $Lines[$j].Contains('{')
            if (-not $hasBody) {
                for ($k = $j + 1; $k -lt [Math]::Min($j + 3, $Lines.Count); $k++) {
                    $next = $Lines[$k].Trim()
                    if ($next -eq '') { continue }
                    if ($next -eq '{' -or $next.StartsWith('{')) { $hasBody = $true }
                    break
                }
            }
            if ($hasBody) { [void]$bounds.Add(@{ Name = $candidate; Line = $j }) }
        }
    }
    return $bounds
}

function Find-FuncCached {
    param($Bounds, [int]$FromIndex)
    for ($b = $Bounds.Count - 1; $b -ge 0; $b--) {
        if ($Bounds[$b].Line -le $FromIndex) { return $Bounds[$b].Name }
    }
    return "(file scope)"
}

# === Scan source files for references ===
$allFiles = @(Get-ChildItem -Path $srcDir -Filter *.ahk -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

$sends = [System.Collections.ArrayList]::new()
$handles = [System.Collections.ArrayList]::new()
$sendLocations = [System.Collections.Generic.HashSet[string]]::new()

# Raw JSON pattern: '{"type":"<msgType>",...}' bypassing IPC_MSG_* constants
$rawPattern = [regex]::Escape('"type":"' + $constValue + '"')

foreach ($file in $allFiles) {
    # File-level pre-filter: ReadAllText for single IndexOf check, split only on match
    $fileText = [System.IO.File]::ReadAllText($file.FullName)
    if ($fileText.IndexOf($constName, [StringComparison]::Ordinal) -lt 0 -and
        $fileText.IndexOf($constValue, [StringComparison]::Ordinal) -lt 0) { continue }

    $lines = $fileText -split '\r?\n'
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $isConstantsFile = ($file.Name -eq "ipc_constants.ahk")

    # Pre-build function boundary map for this file
    $funcBounds = Build-FuncBounds $lines $ahkKeywords

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed[0] -eq ';') { continue }

        $hasConstRef = $constNameRx.IsMatch($line)
        $hasRawJson = $rawPatternRx.IsMatch($trimmed)

        if (-not $hasConstRef -and -not $hasRawJson) { continue }

        $lineNum = $i + 1

        # Process constant reference
        if ($hasConstRef) {
            if ($isConstantsFile -and $constDeclRx.IsMatch($trimmed)) { $hasConstRef = $false }
            elseif ($trimmed -match '^\s*global\s+' -and $trimmed -notmatch ':=') { $hasConstRef = $false }
            elseif ($trimmed -match '^\s*_\w*Log\(' -and $trimmed -notmatch '\btype\b') { $hasConstRef = $false }
        }

        if ($hasConstRef) {
            $funcName = Find-FuncCached $funcBounds $i
            $hit = @{ File = $relPath; Line = $lineNum; Func = $funcName }

            # Classify: send vs handle
            $isSend = $false; $isHandle = $false

            # Handle: comparison (= but not :=), case match, != check
            if ($handleEqRx.IsMatch($trimmed) -or
                $handleCaseRx.IsMatch($trimmed) -or
                $handleNeqRx.IsMatch($trimmed)) { $isHandle = $true }

            # Send: object literal type:, msg["type"] :=, string-built type, ternary
            if ($sendTypeRx.IsMatch($trimmed) -or
                $sendBracketRx.IsMatch($trimmed) -or
                $sendJsonRx.IsMatch($trimmed) -or
                $sendQuoteRx.IsMatch($trimmed) -or
                $sendTernaryRx.IsMatch($trimmed) -or
                $sendTailRx.IsMatch($trimmed)) { $isSend = $true }

            if ($isSend) {
                [void]$sends.Add($hit)
                [void]$sendLocations.Add("$($hit.File):$($hit.Line)")
            }
            elseif ($isHandle) { [void]$handles.Add($hit) }
        }

        # Process raw JSON pattern (supplementary - catches hand-built JSON)
        if ($hasRawJson) {
            # Skip if already found by constant-reference scan (same file+line)
            if (-not $sendLocations.Contains("${relPath}:${lineNum}")) {
                $funcName = Find-FuncCached $funcBounds $i
                [void]$sends.Add(@{ File = $relPath; Line = $lineNum; Func = $funcName })
            }
        }
    }
}

# === Output ===
Write-Host "`n  $constValue" -ForegroundColor White
Write-Host "    constant: $constName (ipc_constants.ahk:$constLine)" -ForegroundColor DarkGray
Write-Host ""

$allHits = @() + $sends + $handles
$maxLocLen = 10
foreach ($h in $allHits) {
    $len = "$($h.File):$($h.Line)".Length
    if ($len -gt $maxLocLen) { $maxLocLen = $len }
}

foreach ($label in @("sent by", "handled by")) {
    $items = if ($label -eq "sent by") { $sends } else { $handles }
    if ($items.Count -gt 0) {
        Write-Host "    ${label}:" -ForegroundColor Cyan
        $sorted = $items | Sort-Object { $_.File }, { $_.Line }
        foreach ($h in $sorted) {
            $loc = "$($h.File):$($h.Line)".PadRight($maxLocLen + 2)
            Write-Host "      $loc [$($h.Func)]" -ForegroundColor Green
        }
    } else {
        Write-Host "    ${label}: (none found)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

$elapsed = $sw.ElapsedMilliseconds
Write-Host "  Completed in ${elapsed}ms" -ForegroundColor DarkGray
