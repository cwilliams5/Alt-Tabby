# check_batch_simple.ps1 - Batched simple pattern checks
# Combines 3 lightweight checks into one PowerShell process to reduce startup overhead.
# Sub-checks: switch_global, ipc_constants, dllcall_types
# Shared file cache: all src/ files (excluding lib/) read once.
#
# Usage: powershell -File tests\check_batch_simple.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all pass, 1 = any check failed

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Resolve source directory ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$projectRoot = (Resolve-Path "$SourceDir\..").Path

# === Shared file cache (single read for all sub-checks) ===
$allFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })
$fileCache = @{}
foreach ($f in $allFiles) {
    $fileCache[$f.FullName] = [System.IO.File]::ReadAllLines($f.FullName)
}

# === Sub-check tracking ===
$subTimings = [System.Collections.ArrayList]::new()
$anyFailed = $false
$failOutput = [System.Text.StringBuilder]::new()

# === Shared helpers ===

function BS_CleanLine {
    param([string]$line)
    if ($line.Length -eq 0) { return '' }
    $trimmed = $line.TrimStart()
    if ($trimmed.Length -eq 0) { return '' }
    if ($trimmed[0] -eq ';') { return '' }
    $cleaned = $line
    if ($line.IndexOf('"') -ge 0) {
        $cleaned = $cleaned -replace '"[^"]*"', '""'
    }
    if ($line.IndexOf("'") -ge 0) {
        $cleaned = $cleaned -replace "'[^']*'", "''"
    }
    if ($cleaned.IndexOf(';') -ge 0) {
        $cleaned = $cleaned -replace '\s;.*$', ''
    }
    return $cleaned
}

function BS_CountBraces {
    param([string]$line)
    $opens = 0; $closes = 0
    foreach ($c in $line.ToCharArray()) {
        if ($c -eq '{') { $opens++ }
        elseif ($c -eq '}') { $closes++ }
    }
    return @($opens, $closes)
}

# ============================================================
# Sub-check 1: switch_global
# Catches global declarations inside switch/case blocks
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$sgIssues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]

    # Pre-filter: skip files without "switch"
    $joined = [string]::Join("`n", $lines)
    if ($joined.IndexOf('switch') -lt 0) { continue }

    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $switchDepthStack = [System.Collections.Generic.Stack[int]]::new()
    $pendingSwitch = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $cleaned = BS_CleanLine $raw
        if ($cleaned -eq '') { continue }

        # Detect switch statement
        if ($cleaned -match '(?<![.\w])switch\b') {
            if ($cleaned -match '\{') {
                $pendingSwitch = $false
                $braces = BS_CountBraces $cleaned
                $newDepth = $depth + $braces[0] - $braces[1]
                $switchDepthStack.Push($depth + 1)
                $depth = $newDepth
                continue
            } else {
                $pendingSwitch = $true
                $braces = BS_CountBraces $cleaned
                $depth += $braces[0] - $braces[1]
                continue
            }
        }

        $braces = BS_CountBraces $cleaned
        $opensOnLine = $braces[0]
        $closesOnLine = $braces[1]

        if ($pendingSwitch -and $opensOnLine -gt 0) {
            $pendingSwitch = $false
            $switchDepthStack.Push($depth + 1)
        }

        # Check for global inside switch block
        if ($switchDepthStack.Count -gt 0 -and $depth -ge $switchDepthStack.Peek()) {
            if ($cleaned -match '(?<![.\w])global\s+\w') {
                [void]$sgIssues.Add([PSCustomObject]@{
                    File = $relPath; Line = $i + 1; Text = $raw.TrimEnd()
                })
            }
        }

        $depth += $opensOnLine - $closesOnLine

        while ($switchDepthStack.Count -gt 0 -and $depth -lt $switchDepthStack.Peek()) {
            [void]$switchDepthStack.Pop()
        }
    }
}

if ($sgIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($sgIssues.Count) global declaration(s) inside switch blocks.")
    [void]$failOutput.AppendLine("  AHK v2 does not allow 'global' inside switch/case - declare at function scope instead.")
    $grouped = $sgIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Text.Trim())")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_switch_global"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 2: ipc_constants
# Ensures IPC message type strings use defined constants
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Load IPC constants from ipc_constants.ahk
$constantsFile = Join-Path $SourceDir "shared\ipc_constants.ahk"
$ipcIssues = [System.Collections.ArrayList]::new()

if (-not (Test-Path $constantsFile)) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: IPC constants file not found: $constantsFile")
} else {
    $constants = @{}
    $constantLines = [System.IO.File]::ReadAllLines($constantsFile)
    foreach ($line in $constantLines) {
        if ($line -match '^\s*global\s+(IPC_MSG_\w+)\s*:=\s*"([^"]+)"') {
            $constants[$Matches[1]] = $Matches[2]
        }
    }

    if ($constants.Count -eq 0) {
        $anyFailed = $true
        [void]$failOutput.AppendLine("")
        [void]$failOutput.AppendLine("  FAIL: No IPC_MSG_* constants found in $constantsFile")
    } else {
        $valueToName = @{}
        foreach ($kv in $constants.GetEnumerator()) { $valueToName[$kv.Value] = $kv.Key }
        $valuesPattern = ($constants.Values | Sort-Object -Descending { $_.Length } | ForEach-Object { [regex]::Escape($_) }) -join '|'

        # Files excluding ipc_constants.ahk itself
        $ipcFiles = @($allFiles | Where-Object { $_.Name -ne "ipc_constants.ahk" })

        # Part A: No hardcoded type strings in JSON
        foreach ($file in $ipcFiles) {
            $lines = $fileCache[$file.FullName]
            $relPath = $file.FullName.Replace("$projectRoot\", '')
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $rawLine = $lines[$i]
                if ($rawLine -match '^\s*;') { continue }
                if ($rawLine -match 'lint-ignore:\s*ipc-constant') { continue }
                if ($rawLine -match "['""]type['""]\s*:\s*['""]($valuesPattern)['""]") {
                    $foundValue = $Matches[1]
                    $expectedConst = $valueToName[$foundValue]
                    if ($rawLine -notmatch [regex]::Escape($expectedConst)) {
                        [void]$ipcIssues.Add([PSCustomObject]@{
                            File = $relPath; Line = $i + 1; Part = 'A'
                            Message = "Hardcoded IPC type string '$foundValue' - use $expectedConst instead"
                        })
                    }
                }
            }
        }

        # Part B: All constants referenced outside ipc_constants.ahk
        $usedConstants = @{}
        foreach ($file in $ipcFiles) {
            $content = [string]::Join("`n", $fileCache[$file.FullName])
            foreach ($constName in $constants.Keys) {
                if ($content.Contains($constName)) { $usedConstants[$constName] = $true }
            }
        }
        foreach ($constName in $constants.Keys | Sort-Object) {
            if (-not $usedConstants.ContainsKey($constName)) {
                [void]$ipcIssues.Add([PSCustomObject]@{
                    File = "src\shared\ipc_constants.ahk"; Line = 0; Part = 'B'
                    Message = "IPC constant $constName is defined but never referenced in any source file"
                })
            }
        }

        # Part C: No raw string comparisons in case statements
        foreach ($file in $ipcFiles) {
            $lines = $fileCache[$file.FullName]
            $relPath = $file.FullName.Replace("$projectRoot\", '')
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $rawLine = $lines[$i]
                if ($rawLine -match '^\s*;') { continue }
                if ($rawLine -match 'lint-ignore:\s*ipc-constant') { continue }
                if ($rawLine -match "^\s*case\s+['""]($valuesPattern)['""]\s*:") {
                    $foundValue = $Matches[1]
                    $expectedConst = $valueToName[$foundValue]
                    [void]$ipcIssues.Add([PSCustomObject]@{
                        File = $relPath; Line = $i + 1; Part = 'C'
                        Message = "Raw string in case statement '$foundValue' - use $expectedConst instead"
                    })
                }
            }
        }
    }
}

if ($ipcIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($ipcIssues.Count) IPC constant issue(s) found.")
    $partAIssues = @($ipcIssues | Where-Object { $_.Part -eq 'A' })
    $partBIssues = @($ipcIssues | Where-Object { $_.Part -eq 'B' })
    $partCIssues = @($ipcIssues | Where-Object { $_.Part -eq 'C' })
    if ($partAIssues.Count -gt 0) {
        [void]$failOutput.AppendLine("  Part A - Hardcoded type strings in JSON ($($partAIssues.Count)):")
        [void]$failOutput.AppendLine("  Fix: replace literal string with IPC_MSG_* constant, or suppress with:")
        [void]$failOutput.AppendLine("    ; lint-ignore: ipc-constant")
        foreach ($issue in $partAIssues | Sort-Object File, Line) {
            [void]$failOutput.AppendLine("    $($issue.File):$($issue.Line): $($issue.Message)")
        }
    }
    if ($partBIssues.Count -gt 0) {
        [void]$failOutput.AppendLine("  Part B - Unused IPC constants ($($partBIssues.Count)):")
        foreach ($issue in $partBIssues | Sort-Object Message) {
            [void]$failOutput.AppendLine("    $($issue.Message)")
        }
    }
    if ($partCIssues.Count -gt 0) {
        [void]$failOutput.AppendLine("  Part C - Raw strings in case statements ($($partCIssues.Count)):")
        [void]$failOutput.AppendLine("  Fix: replace literal string with IPC_MSG_* constant, or suppress with:")
        [void]$failOutput.AppendLine("    ; lint-ignore: ipc-constant")
        foreach ($issue in $partCIssues | Sort-Object File, Line) {
            [void]$failOutput.AppendLine("    $($issue.File):$($issue.Line): $($issue.Message)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_ipc_constants"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 3: dllcall_types
# Catches 32-bit types used for handle/pointer values in DllCall
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$HANDLE_RETURNING = @{}
@(
    'OpenProcess', 'CreateFileW', 'CreateFileA',
    'CreateEventW', 'CreateEventA',
    'CreateMutexW', 'CreateMutexA',
    'CreateNamedPipeW', 'CreateNamedPipeA',
    'CreateThread', 'GetCurrentProcess', 'GetCurrentThread',
    'CreateFileMappingW', 'OpenFileMappingW',
    'MapViewOfFile',
    'LoadLibraryW', 'LoadLibraryA', 'LoadLibraryExW',
    'FindFirstFileW', 'FindFirstFileA',
    'GetModuleHandleW', 'GetModuleHandleA',
    'HeapCreate', 'GetProcessHeap',
    'SetWinEventHook',
    'GetShellWindow', 'GetDesktopWindow', 'GetForegroundWindow',
    'CopyIcon', 'CreateIconIndirect',
    'LoadImageW', 'LoadImageA',
    'GetDC', 'GetWindowDC',
    'CreateWindowExW', 'CreateWindowExA',
    'SetWindowsHookExW', 'SetWindowsHookExA',
    'FindWindowW', 'FindWindowA',
    'GetParent', 'GetAncestor', 'GetWindow',
    'MonitorFromWindow', 'MonitorFromPoint', 'MonitorFromRect',
    'BeginPaint',
    'CreateCompatibleDC', 'CreateDCW',
    'CreateDIBSection', 'CreateBitmap', 'CreateCompatibleBitmap',
    'CreateRoundRectRgn', 'CreateRectRgn', 'CreateEllipticRgn',
    'CreateFontW', 'CreateFontIndirectW',
    'CreatePen', 'ExtCreatePen',
    'CreateSolidBrush', 'CreatePatternBrush',
    'SelectObject', 'GetStockObject'
) | ForEach-Object { $HANDLE_RETURNING[$_] = $true }

$DC_TYPE_SET = @{}
@('int','uint','ptr','uptr','short','ushort','char','uchar','float','double','int64') |
    ForEach-Object { $DC_TYPE_SET[$_] = $true }

$DC_HANDLE_VAR_EXCLUDE = @{ 'hResult' = $true; 'hRes' = $true; 'hPhys' = $true }

function BS_FindDllCallEnd {
    param([string]$text, [int]$openParenIdx)
    $depth = 0; $inStr = $false
    for ($i = $openParenIdx; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($inStr) { if ($c -eq '"') { $inStr = $false }; continue }
        if ($c -eq '"') { $inStr = $true; continue }
        if ($c -eq '(') { $depth++ }
        elseif ($c -eq ')') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return -1
}

function BS_GetParenDelta {
    param([string]$line)
    $c = $line -replace '"[^"]*"', '""'
    $c = $c -replace "'[^']*'", "''"
    $c = $c -replace '\s;.*$', ''
    return ($c.Split('(')).Count - ($c.Split(')')).Count
}

$dcIssues = @()
$dcDllCallCount = 0

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $inBlockComment = $false
    $accumulating = $false
    $joinedLine = ''
    $startLineNum = 0
    $parenDepth = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $lineNum = $i + 1

        if ($inBlockComment) {
            if ($raw -match '\*/') { $inBlockComment = $false }
            if ($accumulating) { $joinedLine += ' ' + $raw }
            continue
        }
        if ($raw -match '^\s*/\*') {
            $inBlockComment = $true
            if ($accumulating) { $joinedLine += ' ' + $raw }
            continue
        }

        if ($accumulating) {
            $joinedLine += ' ' + $raw
            $parenDepth += (BS_GetParenDelta $raw)
            if ($parenDepth -gt 0) { continue }
            $accumulating = $false
        } else {
            if ($raw -match '^\s*;') { continue }
            if ($raw -match 'DllCall\s*\(') {
                if ($raw -match ';\s*lint-ignore:\s*dllcall-types') { continue }
                $joinedLine = $raw
                $startLineNum = $lineNum
                $dllMatch = [regex]::Match($raw, 'DllCall\s*\(')
                $relevantPart = $raw.Substring($dllMatch.Index)
                $parenDepth = (BS_GetParenDelta $relevantPart)
                if ($parenDepth -gt 0) { $accumulating = $true; continue }
            } else { continue }
        }

        # Analyze accumulated DllCall
        $dcDllCallCount++
        $dllMatch = [regex]::Match($joinedLine, 'DllCall\s*\(')
        if (-not $dllMatch.Success) { continue }
        $parenStart = $dllMatch.Index + $dllMatch.Length - 1

        $endIdx = BS_FindDllCallEnd $joinedLine $parenStart
        if ($endIdx -lt 0) { continue }

        $inner = $joinedLine.Substring($parenStart + 1, $endIdx - $parenStart - 1)
        if ($inner -notmatch '^\s*"([^"]+)"') { continue }
        $funcStr = $matches[1]
        $baseName = if ($funcStr -match '\\([^\\]+)$') { $matches[1] } else { $funcStr }

        # Detect return type
        $returnType = $null; $explicitReturn = $false; $lastQuoted = $null
        $scanPos = $inner.Length - 1
        while ($scanPos -ge 0) {
            if ($inner[$scanPos] -eq '"') {
                $closePos = $scanPos; $scanPos--
                while ($scanPos -ge 0 -and $inner[$scanPos] -ne '"') { $scanPos-- }
                if ($scanPos -ge 0) { $lastQuoted = $inner.Substring($scanPos + 1, $closePos - $scanPos - 1) }
                break
            }
            $scanPos--
        }
        if ($lastQuoted) {
            $lq = $lastQuoted.ToLower().Trim()
            if ($lq -match '^cdecl\s+(.+)$') {
                $tp = $matches[1].Trim()
                if ($DC_TYPE_SET.ContainsKey($tp)) { $returnType = $tp; $explicitReturn = $true }
            } elseif ($DC_TYPE_SET.ContainsKey($lq)) { $returnType = $lq; $explicitReturn = $true }
        }
        if (-not $returnType) { $returnType = 'int' }

        $relPath = $file.FullName
        if ($relPath.StartsWith($SourceDir)) {
            $relPath = $relPath.Substring($SourceDir.Length).TrimStart('\', '/')
        }

        # Rule 1: Handle-returning functions must use "Ptr"
        if ($HANDLE_RETURNING.ContainsKey($baseName)) {
            if ($returnType -eq 'int' -or $returnType -eq 'uint') {
                if ($explicitReturn) {
                    $detail = "${baseName}() returns a handle - use `"Ptr`" not `"$lastQuoted`""
                } else {
                    $detail = "${baseName}() returns a handle - return type defaults to `"Int`", use `"Ptr`""
                }
                $dcIssues += [PSCustomObject]@{
                    File = $relPath; Line = $startLineNum; Rule = 'handle-return'; Detail = $detail
                }
            }
        }

        # Rule 2: Handle-like variable passed with "Int"/"UInt"
        $hvMatches = [regex]::Matches($inner, '"([Ii]nt|[Uu][Ii]nt)"\s*,\s*(h[A-Z]\w*)')
        foreach ($m in $hvMatches) {
            $wrongType = $m.Groups[1].Value
            $varName = $m.Groups[2].Value
            if ($DC_HANDLE_VAR_EXCLUDE.ContainsKey($varName)) { continue }
            $dcIssues += [PSCustomObject]@{
                File = $relPath; Line = $startLineNum; Rule = 'handle-param'
                Detail = "$varName looks like a handle - use `"Ptr`" not `"$wrongType`""
            }
        }
    }
}

if ($dcIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($dcIssues.Count) DllCall type issue(s) found.")
    [void]$failOutput.AppendLine("  On 64-bit, handles are pointer-sized. Use `"Ptr`" not `"Int`"/`"UInt`".")
    [void]$failOutput.AppendLine("  Suppress with: ; lint-ignore: dllcall-types")
    $grouped = $dcIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line) [$($issue.Rule)]: $($issue.Detail)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_dllcall_types"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All simple checks passed (switch_global, ipc_constants, dllcall_types)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_simple_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
