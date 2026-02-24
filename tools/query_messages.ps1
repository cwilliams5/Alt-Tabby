# query_messages.ps1 - Windows message handler/sender query
#
# Shows OnMessage handlers and SendMessage/PostMessage senders for Windows messages.
# Maps raw hex constants to human-readable WM_ names.
#
# Usage:
#   powershell -File tools/query_messages.ps1                  (list all messages)
#   powershell -File tools/query_messages.ps1 0x0138           (query by hex)
#   powershell -File tools/query_messages.ps1 WM_CTLCOLORSTATIC  (query by WM_ name)
#   powershell -File tools/query_messages.ps1 GUI_OnClick      (query by handler name)

param(
    [Parameter(Position=0)]
    [string]$Query
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_query_helpers.ps1"
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

# === Pre-built regex for per-line matching (avoids re-parsing pattern strings in hot loop) ===
# NOTE: Using 'IgnoreCase' only (not 'Compiled') — JIT compilation overhead is not
# amortized in short-lived tool processes. .NET regex cache handles the rest.
$rxOnMsgHex       = [regex]::new('OnMessage\(\s*(0x[0-9A-Fa-f]+)\s*,\s*(\w+)')
$rxOnMsgHexAdd    = [regex]::new('OnMessage\([^,]+,[^,]+,\s*(-?\d+)')
$rxOnMsgLambda    = [regex]::new('OnMessage\(\s*(0x[0-9A-Fa-f]+)\s*,\s*\(')
$rxLambdaTarget   = [regex]::new('=>.*?(\w+)\s*\(')
$rxOnMsgConst     = [regex]::new('OnMessage\(\s*(\w+)\s*,\s*(\w+)')
$rxSendPostHex    = [regex]::new('(SendMessage|PostMessage)\s*\(\s*(0x[0-9A-Fa-f]+)')
$rxDllCallHex     = [regex]::new('DllCall\(\s*"[^"]*(?:SendMessage|PostMessage)\w*"[^)]*?(0x[0-9A-Fa-f]+)')
$rxDllCallConst   = [regex]::new('DllCall\(\s*"[^"]*(?:SendMessage|PostMessage)\w*"[^)]*?\b(\w+_WM_\w+|WM_\w+)')
$rxPostMsgConst   = [regex]::new('PostMessage\s*\(\s*(\w+_WM_\w+|WM_\w+)')
# Regex for building per-file constant cache
$rxLocalConst     = [regex]::new('^\s*(?:global\s+)?(\w+)\s*:=\s*(0x[0-9A-Fa-f]+)')

# Helper: resolve a named constant from per-file cache then ipc_constants cache
function Resolve-HexConstant {
    param([string]$Name, [hashtable]$LocalCache)
    if ($LocalCache.ContainsKey($Name)) { return $LocalCache[$Name] }
    if ($ipcConstCache.ContainsKey($Name)) { return $ipcConstCache[$Name] }
    return $null
}

# === Scan source files ===
$allFiles = Get-AhkSourceFiles $srcDir

# Collect all message references
$entries = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    # File-level pre-filter: skip files without any message keyword
    $fileText = [System.IO.File]::ReadAllText($file.FullName)
    if ($fileText.IndexOf('OnMessage', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
        $fileText.IndexOf('SendMessage', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
        $fileText.IndexOf('PostMessage', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
        $fileText.IndexOf('DllCall', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
    $lines = Split-Lines $fileText
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    # Build per-file constant cache: constName -> hex int (replaces O(L) Resolve-HexConstant scans)
    $localConsts = @{}
    foreach ($cl in $lines) {
        $cm = $rxLocalConst.Match($cl)
        if ($cm.Success) { $localConsts[$cm.Groups[1].Value] = [int]$cm.Groups[2].Value }
    }

    $funcBounds = $null  # lazy init: defer boundary building to first match

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed[0] -eq ';') { continue }

        # Quick keyword gate: skip lines that can't match any pattern
        if ($line.IndexOf('OnMessage', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
            $line.IndexOf('SendMessage', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
            $line.IndexOf('PostMessage', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
            $line.IndexOf('DllCall', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }

        # Lazy init function boundaries on first keyword-matching line
        if (-not $funcBounds) {
            $funcBounds = Build-FuncBoundaryMap $lines
        }

        # OnMessage(0xNNNN, handler) or OnMessage(0xNNNN, handler, addRemove)
        $rm = $rxOnMsgHex.Match($trimmed)
        if ($rm.Success) {
            $hexVal = [int]$rm.Groups[1].Value
            $handler = $rm.Groups[2].Value
            $addRemove = ""
            $ra = $rxOnMsgHexAdd.Match($trimmed)
            if ($ra.Success) { $addRemove = $ra.Groups[1].Value }
            [void]$entries.Add(@{
                Hex     = $hexVal
                Type    = if ($addRemove -eq "0") { "unregister" } else { "register" }
                Handler = $handler
                File    = $relPath
                Line    = $i + 1
                Func    = Find-EnclosingFunction $funcBounds $i
            })
            continue
        }

        # OnMessage(0xNNNN, (...) => ...) — lambda handlers
        $rm = $rxOnMsgLambda.Match($trimmed)
        if ($rm.Success) {
            $hexVal = [int]$rm.Groups[1].Value
            # Extract the primary function called inside the lambda
            $handler = "(lambda)"
            $rl = $rxLambdaTarget.Match($trimmed)
            if ($rl.Success) {
                $called = $rl.Groups[1].Value
                if (-not $AHK_KEYWORDS_SET.Contains($called)) { $handler = "(lambda -> $called)" }
            }
            [void]$entries.Add(@{
                Hex     = $hexVal
                Type    = "register"
                Handler = $handler
                File    = $relPath
                Line    = $i + 1
                Func    = Find-EnclosingFunction $funcBounds $i
            })
            continue
        }

        # OnMessage with named constant variable: OnMessage(WM_COPYDATA, handler)
        $rm = $rxOnMsgConst.Match($trimmed)
        if ($rm.Success) {
            $constName = $rm.Groups[1].Value
            $handler = $rm.Groups[2].Value
            $resolved = Resolve-HexConstant $constName $localConsts
            if ($resolved) {
                $addRemove = ""
                $ra = $rxOnMsgHexAdd.Match($trimmed)
                if ($ra.Success) { $addRemove = $ra.Groups[1].Value }
                [void]$entries.Add(@{
                    Hex     = $resolved
                    Type    = if ($addRemove -eq "0") { "unregister" } else { "register" }
                    Handler = $handler
                    File    = $relPath
                    Line    = $i + 1
                    Func    = Find-EnclosingFunction $funcBounds $i
                })
            }
            continue
        }

        # SendMessage / PostMessage with hex literal
        $rm = $rxSendPostHex.Match($trimmed)
        if ($rm.Success) {
            $verb = $rm.Groups[1].Value
            $hexVal = [int]$rm.Groups[2].Value
            [void]$entries.Add(@{
                Hex     = $hexVal
                Type    = $verb.ToLower()
                Handler = ""
                File    = $relPath
                Line    = $i + 1
                Func    = Find-EnclosingFunction $funcBounds $i
            })
            continue
        }

        # DllCall SendMessage/PostMessage variants with hex literal
        $rm = $rxDllCallHex.Match($trimmed)
        if ($rm.Success) {
            $hexVal = [int]$rm.Groups[1].Value
            $verb = if ($trimmed.IndexOf('PostMessage', [StringComparison]::OrdinalIgnoreCase) -ge 0) { "postmessage" } else { "sendmessage" }
            [void]$entries.Add(@{
                Hex     = $hexVal
                Type    = $verb
                Handler = ""
                File    = $relPath
                Line    = $i + 1
                Func    = Find-EnclosingFunction $funcBounds $i
            })
            continue
        }

        # DllCall SendMessage/PostMessage with named constant (e.g., IP_WM_GETICON)
        $rm = $rxDllCallConst.Match($trimmed)
        if ($rm.Success) {
            $constName = $rm.Groups[1].Value
            # Resolve from file-local cache only (matches original behavior)
            $resolved = if ($localConsts.ContainsKey($constName)) { $localConsts[$constName] } else { $null }
            if ($resolved) {
                $verb = if ($trimmed.IndexOf('PostMessage', [StringComparison]::OrdinalIgnoreCase) -ge 0) { "postmessage" } else { "sendmessage" }
                [void]$entries.Add(@{
                    Hex     = $resolved
                    Type    = $verb
                    Handler = ""
                    File    = $relPath
                    Line    = $i + 1
                    Func    = Find-EnclosingFunction $funcBounds $i
                })
            }
            continue
        }

        # PostMessage with named constant (non-DllCall)
        $rm = $rxPostMsgConst.Match($trimmed)
        if ($rm.Success) {
            $constName = $rm.Groups[1].Value
            $resolved = Resolve-HexConstant $constName $localConsts
            if ($resolved) {
                [void]$entries.Add(@{
                    Hex     = $resolved
                    Type    = "postmessage"
                    Handler = ""
                    File    = $relPath
                    Line    = $i + 1
                    Func    = Find-EnclosingFunction $funcBounds $i
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
