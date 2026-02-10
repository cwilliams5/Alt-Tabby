# query_ipc.ps1 - IPC message flow query
#
# Shows who sends and who handles each IPC message type.
#
# Usage:
#   powershell -File tests/query_ipc.ps1                   (list all message types)
#   powershell -File tests/query_ipc.ps1 snapshot           (query by string value)
#   powershell -File tests/query_ipc.ps1 IPC_MSG_SNAPSHOT   (query by constant name)

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

# === Scan source files for references ===
$allFiles = @(Get-ChildItem -Path $srcDir -Filter *.ahk -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

$sends = [System.Collections.ArrayList]::new()
$handles = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $isConstantsFile = ($file.Name -eq "ipc_constants.ahk")

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $trimmed = $line.Trim()

        # Word-boundary match (avoids IPC_MSG_SNAPSHOT matching IPC_MSG_SNAPSHOT_REQUEST)
        if ($line -notmatch "\b$constName\b") { continue }
        if ($trimmed -match '^\s*;') { continue }
        if ($isConstantsFile -and $trimmed -match "^\s*global\s+$constName\b\s*:=") { continue }
        if ($trimmed -match '^\s*global\s+' -and $trimmed -notmatch ':=') { continue }
        if ($trimmed -match '^\s*_\w*Log\(' -and $trimmed -notmatch '\btype\b') { continue }

        # Find enclosing function: scan backwards for definition at column 0 with body brace
        $funcName = "(file scope)"
        for ($j = $i - 1; $j -ge 0; $j--) {
            if ($lines[$j] -match '^(\w+)\s*\(') {
                $candidate = $Matches[1]
                if ($candidate.ToLower() -in $ahkKeywords) { continue }
                $hasBody = $lines[$j].Contains('{')
                if (-not $hasBody) {
                    for ($k = $j + 1; $k -lt [Math]::Min($j + 3, $lines.Count); $k++) {
                        $next = $lines[$k].Trim()
                        if ($next -eq '') { continue }
                        if ($next -eq '{' -or $next.StartsWith('{')) { $hasBody = $true }
                        break
                    }
                }
                if ($hasBody) { $funcName = $candidate; break }
            }
        }

        $lineNum = $i + 1
        $hit = @{ File = $relPath; Line = $lineNum; Func = $funcName }

        # Classify: send vs handle
        $isSend = $false; $isHandle = $false

        # Handle: comparison (= but not :=), case match, != check
        if ($trimmed -match "(?<!:)=\s*$constName\b" -or
            $trimmed -match "case\s+$constName\b" -or
            $trimmed -match "!=\s*$constName\b") { $isHandle = $true }

        # Send: object literal type:, msg["type"] :=, string-built type, ternary
        if ($trimmed -match "type:\s*$constName\b" -or
            $trimmed -match "\[`"type`"\]\s*:=\s*$constName\b" -or
            $trimmed -match "type`":\s*`".*\b$constName\b" -or
            $trimmed -match "'.*type.*\b$constName\b" -or
            $trimmed -match "\?\s*$constName\b" -or
            $trimmed -match ":\s*$constName\s*$") { $isSend = $true }

        if ($isSend) { [void]$sends.Add($hit) }
        elseif ($isHandle) { [void]$handles.Add($hit) }
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
