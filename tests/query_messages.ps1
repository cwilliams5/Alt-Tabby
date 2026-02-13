# query_messages.ps1 - Windows message handler/sender query
#
# Shows OnMessage handlers and SendMessage/PostMessage senders for Windows messages.
# Maps raw hex constants to human-readable WM_ names.
#
# Usage:
#   powershell -File tests/query_messages.ps1                  (list all messages)
#   powershell -File tests/query_messages.ps1 0x0138           (query by hex)
#   powershell -File tests/query_messages.ps1 WM_CTLCOLORSTATIC  (query by WM_ name)
#   powershell -File tests/query_messages.ps1 GUI_OnClick      (query by handler name)

param(
    [Parameter(Position=0)]
    [string]$Query
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$projectRoot = Split-Path $PSScriptRoot -Parent
$srcDir = Join-Path $projectRoot "src"

# === Hex-to-name lookup table (messages used in this codebase) ===
$WM_NAMES = @{
    0x000B = "WM_SETREDRAW"
    0x0010 = "WM_CLOSE"
    0x001A = "WM_SETTINGCHANGE"
    0x002B = "WM_DRAWITEM"
    0x0031 = "WM_GETFONT"
    0x004A = "WM_COPYDATA"
    0x004E = "WM_NOTIFY"
    0x007F = "WM_GETICON"
    0x00D3 = "EM_SETSEL"
    0x0115 = "WM_VSCROLL"
    0x0133 = "WM_CTLCOLOREDIT"
    0x0134 = "WM_CTLCOLORLISTBOX"
    0x0138 = "WM_CTLCOLORSTATIC"
    0x0200 = "WM_MOUSEMOVE"
    0x0201 = "WM_LBUTTONDOWN"
    0x020A = "WM_MOUSEWHEEL"
    0x02A3 = "WM_MOUSELEAVE"
    0x02E0 = "WM_DPICHANGED"
    0x031A = "WM_THEMECHANGED"
    0x0404 = "WM_TRAYICON"
    0x0418 = "TTM_SETMAXTIPWIDTH"
    0x0419 = "TBM_GETTHUMBRECT"
    0x0432 = "TTM_ADDTOOLW"
    0x0439 = "TTM_UPDATETIPTEXTW"
    0x1001 = "LVM_SETBKCOLOR"
    0x101F = "LVM_GETHEADER"
    0x1024 = "LVM_SETTEXTCOLOR"
    0x1026 = "LVM_SETTEXTBKCOLOR"
    0x1304 = "TCM_GETITEMCOUNT"
    0x130A = "TCM_GETITEMRECT"
    0x133C = "TCM_SETITEM"
    0x1501 = "EM_SETCUEBANNER"
    0x2001 = "PBM_SETBKCOLOR"
    0x8001 = "IPC_WM_PIPE_WAKE"
}

# Build reverse lookup: name -> hex
$NAME_TO_HEX = @{}
foreach ($kv in $WM_NAMES.GetEnumerator()) {
    $NAME_TO_HEX[$kv.Value.ToLower()] = $kv.Key
}

# === Helpers ===
$ahkKeywords = @('if','else','while','for','loop','switch','case','catch','finally',
    'try','return','throw','not','and','or','is','in','contains','isset')

function Build-FunctionBoundaries {
    param([string[]]$Lines, [string[]]$Keywords)
    $boundaries = [System.Collections.ArrayList]::new()
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
            if ($hasBody) { [void]$boundaries.Add(@{ Name = $candidate; Line = $j }) }
        }
    }
    return $boundaries
}

function Find-EnclosingFunctionCached {
    param($Boundaries, [int]$FromIndex)
    for ($b = $Boundaries.Count - 1; $b -ge 0; $b--) {
        if ($Boundaries[$b].Line -le $FromIndex) { return $Boundaries[$b].Name }
    }
    return "(file scope)"
}

function Format-MsgHex { param([int]$val) return "0x{0:X04}" -f $val }

# === Pre-cache ipc_constants.ahk hex constants for O(1) resolution ===
$ipcConstCache = @{}
$ipcConstFile = Join-Path $srcDir "shared\ipc_constants.ahk"
if (Test-Path $ipcConstFile) {
    foreach ($cl in [System.IO.File]::ReadAllLines($ipcConstFile)) {
        if ($cl -match '^\s*global\s+(\w+)\s*:=\s*(0x[0-9A-Fa-f]+)') {
            $ipcConstCache[$Matches[1]] = [int]$Matches[2]
        }
    }
}

# Helper: resolve a named constant to hex value (file-local then ipc_constants cache)
function Resolve-HexConstant {
    param([string]$Name, [string[]]$FileLines)
    for ($j = 0; $j -lt $FileLines.Count; $j++) {
        if ($FileLines[$j] -match "^\s*(?:global\s+)?$Name\s*:=\s*(0x[0-9A-Fa-f]+)") {
            return [int]$Matches[1]
        }
    }
    if ($ipcConstCache.ContainsKey($Name)) { return $ipcConstCache[$Name] }
    return $null
}

# === Scan source files ===
$allFiles = @(Get-ChildItem -Path $srcDir -Filter *.ahk -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

# Collect all message references
$entries = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    # Pre-build function boundary map for this file (Opt 5)
    $funcBounds = Build-FunctionBoundaries $lines $ahkKeywords

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed[0] -eq ';') { continue }

        # Quick keyword gate: skip lines that can't match any pattern (Opt 2)
        if ($line.IndexOf('OnMessage', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
            $line.IndexOf('SendMessage', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
            $line.IndexOf('PostMessage', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
            $line.IndexOf('DllCall', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }

        # OnMessage(0xNNNN, handler) or OnMessage(0xNNNN, handler, addRemove)
        if ($trimmed -match 'OnMessage\(\s*(0x[0-9A-Fa-f]+)\s*,\s*(\w+)') {
            $hexVal = [int]$Matches[1]
            $handler = $Matches[2]
            $addRemove = ""
            if ($trimmed -match 'OnMessage\([^,]+,[^,]+,\s*(-?\d+)') { $addRemove = $Matches[1] }
            [void]$entries.Add(@{
                Hex     = $hexVal
                Type    = if ($addRemove -eq "0") { "unregister" } else { "register" }
                Handler = $handler
                File    = $relPath
                Line    = $i + 1
                Func    = Find-EnclosingFunctionCached $funcBounds $i
            })
            continue
        }

        # OnMessage(0xNNNN, (...) => ...) — lambda handlers
        if ($trimmed -match 'OnMessage\(\s*(0x[0-9A-Fa-f]+)\s*,\s*\(') {
            $hexVal = [int]$Matches[1]
            # Extract the primary function called inside the lambda
            $handler = "(lambda)"
            if ($trimmed -match '=>.*?(\w+)\s*\(') {
                $called = $Matches[1]
                if ($called.ToLower() -notin $ahkKeywords) { $handler = "(lambda -> $called)" }
            }
            [void]$entries.Add(@{
                Hex     = $hexVal
                Type    = "register"
                Handler = $handler
                File    = $relPath
                Line    = $i + 1
                Func    = Find-EnclosingFunctionCached $funcBounds $i
            })
            continue
        }

        # OnMessage with named constant variable: OnMessage(WM_COPYDATA, handler)
        if ($trimmed -match 'OnMessage\(\s*(\w+)\s*,\s*(\w+)') {
            $constName = $Matches[1]
            $handler = $Matches[2]
            $resolved = Resolve-HexConstant $constName $lines
            if ($resolved) {
                $addRemove = ""
                if ($trimmed -match 'OnMessage\([^,]+,[^,]+,\s*(-?\d+)') { $addRemove = $Matches[1] }
                [void]$entries.Add(@{
                    Hex     = $resolved
                    Type    = if ($addRemove -eq "0") { "unregister" } else { "register" }
                    Handler = $handler
                    File    = $relPath
                    Line    = $i + 1
                    Func    = Find-EnclosingFunctionCached $funcBounds $i
                })
            }
            continue
        }

        # SendMessage / PostMessage with hex literal
        if ($trimmed -match '(SendMessage|PostMessage)\s*\(\s*(0x[0-9A-Fa-f]+)') {
            $verb = $Matches[1]
            $hexVal = [int]$Matches[2]
            [void]$entries.Add(@{
                Hex     = $hexVal
                Type    = $verb.ToLower()
                Handler = ""
                File    = $relPath
                Line    = $i + 1
                Func    = Find-EnclosingFunctionCached $funcBounds $i
            })
            continue
        }

        # DllCall SendMessage/PostMessage variants with hex literal
        if ($trimmed -match 'DllCall\(\s*"[^"]*(?:SendMessage|PostMessage)\w*"[^)]*?(0x[0-9A-Fa-f]+)') {
            $hexVal = [int]$Matches[1]
            $verb = if ($trimmed -match 'PostMessage') { "postmessage" } else { "sendmessage" }
            [void]$entries.Add(@{
                Hex     = $hexVal
                Type    = $verb
                Handler = ""
                File    = $relPath
                Line    = $i + 1
                Func    = Find-EnclosingFunctionCached $funcBounds $i
            })
            continue
        }

        # SendMessage with named constant in DllCall (e.g., IP_WM_GETICON)
        # Note: only resolves from current file (not ipc_constants) to match original behavior
        if ($trimmed -match 'DllCall\(\s*"[^"]*(?:SendMessage|PostMessage)\w*"[^)]*?\b(\w+_WM_\w+|WM_\w+)') {
            $constName = $Matches[1]
            $resolved = $null
            for ($j = 0; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -match "^\s*(?:global\s+)?$constName\s*:=\s*(0x[0-9A-Fa-f]+)") {
                    $resolved = [int]$Matches[1]
                    break
                }
            }
            if ($resolved) {
                $verb = if ($trimmed -match 'PostMessage') { "postmessage" } else { "sendmessage" }
                [void]$entries.Add(@{
                    Hex     = $resolved
                    Type    = $verb
                    Handler = ""
                    File    = $relPath
                    Line    = $i + 1
                    Func    = Find-EnclosingFunctionCached $funcBounds $i
                })
            }
            continue
        }

        # PostMessage with named constant (non-DllCall)
        if ($trimmed -match 'PostMessage\s*\(\s*(\w+_WM_\w+|WM_\w+)') {
            $constName = $Matches[1]
            $resolved = Resolve-HexConstant $constName $lines
            if ($resolved) {
                [void]$entries.Add(@{
                    Hex     = $resolved
                    Type    = "postmessage"
                    Handler = ""
                    File    = $relPath
                    Line    = $i + 1
                    Func    = Find-EnclosingFunctionCached $funcBounds $i
                })
            }
            continue
        }
    }
}

# === Deduplicate (same file+line can match multiple patterns) ===
$seen = @{}
$unique = [System.Collections.ArrayList]::new()
foreach ($e in $entries) {
    $key = "$($e.File):$($e.Line):$($e.Type)"
    if (-not $seen.ContainsKey($key)) {
        $seen[$key] = $true
        [void]$unique.Add($e)
    }
}
$entries = $unique

# === Group by hex value ===
$byHex = @{}
foreach ($e in $entries) {
    $h = $e.Hex
    if (-not $byHex.ContainsKey($h)) { $byHex[$h] = [System.Collections.ArrayList]::new() }
    [void]$byHex[$h].Add($e)
}

# === No-arg mode: list all messages ===
if (-not $Query) {
    $sortedHexes = $byHex.Keys | Sort-Object

    # Group: OnMessage handlers vs SendMessage-only
    $handlerMsgs = [System.Collections.ArrayList]::new()
    $sendOnlyMsgs = [System.Collections.ArrayList]::new()

    foreach ($h in $sortedHexes) {
        $items = $byHex[$h]
        $hasHandler = $false
        foreach ($item in $items) {
            if ($item.Type -eq "register" -or $item.Type -eq "unregister") { $hasHandler = $true; break }
        }
        $name = if ($WM_NAMES.ContainsKey($h)) { $WM_NAMES[$h] } else { "?" }
        $hex = Format-MsgHex $h
        $registerCount = @($items | Where-Object { $_.Type -eq "register" }).Count
        $sendCount = @($items | Where-Object { $_.Type -eq "sendmessage" -or $_.Type -eq "postmessage" }).Count
        $entry = @{ Hex = $hex; Name = $name; Registers = $registerCount; Sends = $sendCount; HexVal = $h }

        if ($hasHandler) { [void]$handlerMsgs.Add($entry) }
        else { [void]$sendOnlyMsgs.Add($entry) }
    }

    # Detect conflicts (multiple registrations for same message from different files)
    $conflicts = [System.Collections.ArrayList]::new()
    foreach ($h in $sortedHexes) {
        $items = $byHex[$h]
        $regFiles = @($items | Where-Object { $_.Type -eq "register" } | ForEach-Object { $_.File } | Sort-Object -Unique)
        if ($regFiles.Count -gt 1) {
            $name = if ($WM_NAMES.ContainsKey($h)) { $WM_NAMES[$h] } else { Format-MsgHex $h }
            [void]$conflicts.Add(@{ Name = $name; Hex = (Format-MsgHex $h); Files = $regFiles })
        }
    }

    Write-Host ""
    Write-Host "  Windows Messages ($($sortedHexes.Count) types)" -ForegroundColor White
    Write-Host ""

    if ($handlerMsgs.Count -gt 0) {
        Write-Host "  OnMessage handlers ($($handlerMsgs.Count)):" -ForegroundColor Cyan
        $maxNameLen = ($handlerMsgs | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
        foreach ($m in $handlerMsgs) {
            $padded = $m.Name.PadRight($maxNameLen + 2)
            $detail = $m.Hex
            if ($m.Sends -gt 0) { $detail += "  (+$($m.Sends) send)" }
            Write-Host "    $padded $detail" -ForegroundColor Green
        }
        Write-Host ""
    }

    if ($sendOnlyMsgs.Count -gt 0) {
        Write-Host "  Send/Post only ($($sendOnlyMsgs.Count)):" -ForegroundColor Cyan
        $maxNameLen = ($sendOnlyMsgs | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
        foreach ($m in $sendOnlyMsgs) {
            $padded = $m.Name.PadRight($maxNameLen + 2)
            Write-Host "    $padded $($m.Hex)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    if ($conflicts.Count -gt 0) {
        Write-Host "  Potential conflicts ($($conflicts.Count)):" -ForegroundColor Yellow
        foreach ($c in $conflicts) {
            Write-Host "    $($c.Name) ($($c.Hex)) registered in:" -ForegroundColor Yellow
            foreach ($f in $c.Files) {
                Write-Host "      $f" -ForegroundColor Red
            }
        }
        Write-Host ""
    }

    Write-Host "  Query: query_messages.ps1 <hex|WM_name|handler>" -ForegroundColor DarkGray
    $elapsed = $sw.ElapsedMilliseconds
    Write-Host "  Completed in ${elapsed}ms" -ForegroundColor DarkGray
    exit 0
}

# === Query mode ===
$targetHex = $null
$queryLower = $Query.ToLower()

# 1. Try hex literal
if ($Query -match '^0x[0-9A-Fa-f]+$') {
    $targetHex = [int]$Query
}

# 2. Try WM_ name lookup
if (-not $targetHex -and $NAME_TO_HEX.ContainsKey($queryLower)) {
    $targetHex = $NAME_TO_HEX[$queryLower]
}

# 3. Try partial WM_ name match
if (-not $targetHex) {
    $partials = @($NAME_TO_HEX.Keys | Where-Object { $_ -like "*$queryLower*" })
    if ($partials.Count -eq 1) {
        $targetHex = $NAME_TO_HEX[$partials[0]]
    } elseif ($partials.Count -gt 1) {
        Write-Host "`n  Ambiguous name: '$Query' matches $($partials.Count) messages:" -ForegroundColor Yellow
        foreach ($p in ($partials | Sort-Object)) {
            $h = Format-MsgHex $NAME_TO_HEX[$p]
            Write-Host "    $($p.ToUpper())  $h" -ForegroundColor Cyan
        }
        Write-Host ""; exit 1
    }
}

# 4. Try handler function name match
if (-not $targetHex) {
    $handlerMatches = @($entries | Where-Object {
        $_.Handler -and ($_.Handler -ieq $Query -or $_.Handler.ToLower().Contains($queryLower))
    })
    if ($handlerMatches.Count -gt 0) {
        $matchedHexes = @($handlerMatches | ForEach-Object { $_.Hex } | Sort-Object -Unique)
        if ($matchedHexes.Count -eq 1) {
            $targetHex = $matchedHexes[0]
        } else {
            Write-Host "`n  Handler '$Query' handles $($matchedHexes.Count) messages:" -ForegroundColor Yellow
            foreach ($h in $matchedHexes) {
                $name = if ($WM_NAMES.ContainsKey($h)) { $WM_NAMES[$h] } else { "?" }
                Write-Host "    $name  $(Format-MsgHex $h)" -ForegroundColor Cyan
            }
            Write-Host ""; exit 1
        }
    }
}

if (-not $targetHex -or -not $byHex.ContainsKey($targetHex)) {
    Write-Host "`n  Unknown message: '$Query'" -ForegroundColor Red
    Write-Host "  Try: hex (0x0138), WM_ name (WM_CTLCOLORSTATIC), or handler function name" -ForegroundColor DarkGray
    Write-Host ""; exit 1
}

# === Output query result ===
$name = if ($WM_NAMES.ContainsKey($targetHex)) { $WM_NAMES[$targetHex] } else { "?" }
$hex = Format-MsgHex $targetHex
$items = $byHex[$targetHex]

Write-Host ""
Write-Host "  $name  ($hex)" -ForegroundColor White
Write-Host ""

# Compute max location length for alignment
$maxLocLen = 10
foreach ($e in $items) {
    $len = "$($e.File):$($e.Line)".Length
    if ($len -gt $maxLocLen) { $maxLocLen = $len }
}

# Group by type
$registers = @($items | Where-Object { $_.Type -eq "register" } | Sort-Object { $_.File }, { $_.Line })
$unregisters = @($items | Where-Object { $_.Type -eq "unregister" } | Sort-Object { $_.File }, { $_.Line })
$sends = @($items | Where-Object { $_.Type -eq "sendmessage" } | Sort-Object { $_.File }, { $_.Line })
$posts = @($items | Where-Object { $_.Type -eq "postmessage" } | Sort-Object { $_.File }, { $_.Line })

foreach ($group in @(
    @{ Label = "OnMessage handlers"; Items = $registers; Color = "Green" },
    @{ Label = "OnMessage removals"; Items = $unregisters; Color = "DarkYellow" },
    @{ Label = "SendMessage"; Items = $sends; Color = "Cyan" },
    @{ Label = "PostMessage"; Items = $posts; Color = "DarkCyan" }
)) {
    if ($group.Items.Count -gt 0) {
        Write-Host "    $($group.Label):" -ForegroundColor Cyan
        foreach ($e in $group.Items) {
            $loc = "$($e.File):$($e.Line)".PadRight($maxLocLen + 2)
            $handler = if ($e.Handler) { " -> $($e.Handler)" } else { "" }
            Write-Host "      $loc [$($e.Func)]$handler" -ForegroundColor $group.Color
        }
        Write-Host ""
    }
}

# Conflict warning
$regFiles = @($registers | ForEach-Object { $_.File } | Sort-Object -Unique)
if ($regFiles.Count -gt 1) {
    Write-Host "    WARNING: Multiple files register handlers for this message" -ForegroundColor Yellow
    Write-Host ""
}

$elapsed = $sw.ElapsedMilliseconds
Write-Host "  Completed in ${elapsed}ms" -ForegroundColor DarkGray
