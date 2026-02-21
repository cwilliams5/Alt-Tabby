# check_batch_simple.ps1 - Batched simple pattern checks
# Combines 14 lightweight checks into one PowerShell process to reduce startup overhead.
# Sub-checks: switch_global, ipc_constants, dllcall_types, isset_with_default, cfg_properties, duplicate_functions, fileappend_encoding, lint_ignore_orphans, static_in_timers, timer_lifecycle, dead_config, dead_globals, dead_locals, dead_params
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
$fileCacheText = @{}
foreach ($f in $allFiles) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    $fileCacheText[$f.FullName] = $text
    $lines = $text -split "`r?`n"
    $fileCache[$f.FullName] = $lines
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

$BS_AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)

# === Pre-compute cleaned lines and brace counts (reused by multiple sub-checks) ===
$processedCache = @{}
foreach ($f in $allFiles) {
    $lines = $fileCache[$f.FullName]
    $processed = [object[]]::new($lines.Count)
    for ($li = 0; $li -lt $lines.Count; $li++) {
        $cleaned = BS_CleanLine $lines[$li]
        $braces = if ($cleaned -ne '') { BS_CountBraces $cleaned } else { @(0, 0) }
        $processed[$li] = @{ Raw = $lines[$li]; Cleaned = $cleaned; Braces = $braces }
    }
    $processedCache[$f.FullName] = $processed
}

# ============================================================
# Sub-check 1: switch_global
# Catches global declarations inside switch/case blocks
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$sgIssues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    # Pre-filter: skip files without both "switch" and "global" (need both for violation)
    $joined = $fileCacheText[$file.FullName]
    if ($joined.IndexOf('switch', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
    if ($joined.IndexOf('global', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

    $processed = $processedCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $switchDepthStack = [System.Collections.Generic.Stack[int]]::new()
    $pendingSwitch = $false

    for ($i = 0; $i -lt $processed.Count; $i++) {
        $ld = $processed[$i]
        $cleaned = $ld.Cleaned
        if ($cleaned -eq '') { continue }

        # Detect switch statement
        if ($cleaned -match '(?<![.\w])switch\b') {
            if ($cleaned -match '\{') {
                $pendingSwitch = $false
                $newDepth = $depth + $ld.Braces[0] - $ld.Braces[1]
                $switchDepthStack.Push($depth + 1)
                $depth = $newDepth
                continue
            } else {
                $pendingSwitch = $true
                $depth += $ld.Braces[0] - $ld.Braces[1]
                continue
            }
        }

        $opensOnLine = $ld.Braces[0]
        $closesOnLine = $ld.Braces[1]

        if ($pendingSwitch -and $opensOnLine -gt 0) {
            $pendingSwitch = $false
            $switchDepthStack.Push($depth + 1)
        }

        # Check for global inside switch block
        if ($switchDepthStack.Count -gt 0 -and $depth -ge $switchDepthStack.Peek()) {
            if ($cleaned -match '(?<![.\w])global\s+\w') {
                [void]$sgIssues.Add([PSCustomObject]@{
                    File = $relPath; Line = $i + 1; Text = $ld.Raw.TrimEnd()
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
            $content = $fileCacheText[$file.FullName]
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

        # Part D: IPC send/handle symmetry
        # Verifies each used constant appears in BOTH handler (type comparison) AND sender (type construction) contexts.
        # A constant only in send = message sent but nobody handles it.
        # A constant only in handle = handler exists but nobody sends the message.
        # Detection: "type: IPC_MSG_*" = send (object construction), "type = IPC_MSG_*" = handle (dispatch comparison).
        # Suppress: ; lint-ignore: ipc-symmetry (on the constant definition in ipc_constants.ahk)
        $constInHandle = [System.Collections.Generic.HashSet[string]]::new()
        $constInSend = [System.Collections.Generic.HashSet[string]]::new()
        $ipcSymSuppressed = [System.Collections.Generic.HashSet[string]]::new()

        # Check for suppression on constant definition lines
        foreach ($line in $constantLines) {
            if ($line -match 'lint-ignore:\s*ipc-symmetry' -and $line -match 'global\s+(IPC_MSG_\w+)') {
                [void]$ipcSymSuppressed.Add($Matches[1])
            }
        }

        foreach ($file in $ipcFiles) {
            $content = $fileCacheText[$file.FullName]
            $lines = $fileCache[$file.FullName]
            foreach ($constName in $constants.Keys) {
                if (-not $content.Contains($constName)) { continue }
                $escapedName = [regex]::Escape($constName)
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $rawLine = $lines[$i]
                    if (-not $rawLine.Contains($constName)) { continue }
                    if ($rawLine -match '^\s*;') { continue }
                    # Handle context: type equality/inequality comparison (guard clause: != is also a handler)
                    if ($rawLine -match "type\s*!?={1,2}\s*$escapedName\b" -or
                        $rawLine -match "\[.type.\]\s*!?={1,2}\s*$escapedName\b" -or
                        $rawLine -match "^\s*case\b.*\b$escapedName\b") {
                        [void]$constInHandle.Add($constName)
                    }
                    # Send context: type construction (object literal, Map assignment, Map constructor, string concat)
                    if ($rawLine -match "type:\s*$escapedName\b" -or
                        $rawLine -match "\[.type.\]\s*:=\s*$escapedName\b" -or
                        $rawLine -match "Map\s*\(\s*['""]type['""].*$escapedName\b" -or
                        $rawLine -match "['""]type['""].*['""].*$escapedName\b") {
                        [void]$constInSend.Add($constName)
                    }
                }
            }
        }

        foreach ($constName in $constants.Keys | Sort-Object) {
            if (-not $usedConstants.ContainsKey($constName)) { continue }
            if ($ipcSymSuppressed.Contains($constName)) { continue }
            $inHandle = $constInHandle.Contains($constName)
            $inSend = $constInSend.Contains($constName)
            if ($inSend -and -not $inHandle) {
                [void]$ipcIssues.Add([PSCustomObject]@{
                    File = "src\shared\ipc_constants.ahk"; Line = 0; Part = 'D'
                    Message = "$constName is sent but no handler dispatches it"
                })
            } elseif ($inHandle -and -not $inSend) {
                [void]$ipcIssues.Add([PSCustomObject]@{
                    File = "src\shared\ipc_constants.ahk"; Line = 0; Part = 'D'
                    Message = "$constName has a handler but no send-side construction"
                })
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
    $partDIssues = @($ipcIssues | Where-Object { $_.Part -eq 'D' })
    if ($partDIssues.Count -gt 0) {
        [void]$failOutput.AppendLine("  Part D - IPC send/handle symmetry ($($partDIssues.Count)):")
        [void]$failOutput.AppendLine("  Each IPC constant should appear in both send (type: CONST) and handler (type = CONST) contexts.")
        [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: ipc-symmetry' on the constant definition line.")
        foreach ($issue in $partDIssues | Sort-Object Message) {
            [void]$failOutput.AppendLine("    $($issue.Message)")
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
# Sub-check 4: isset_with_default
# Detects IsSet() calls on globals declared with a default value.
# IsSet() returns true for ANY assigned value (including 0, false, ""),
# so such checks are always true -- likely a bug.
# Suppress: ; lint-ignore: isset-with-default
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Phase 1: Collect file-scope global declarations WITH defaults
$idGlobalsWithDefaults = @{}  # varName -> @{ Name; File; Line }

foreach ($file in $allFiles) {
    $processed = $processedCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0

    for ($i = 0; $i -lt $processed.Count; $i++) {
        $ld = $processed[$i]
        $cleaned = $ld.Cleaned
        if ($cleaned -eq '') { continue }

        # Only look at file-scope (depth == 0) global declarations
        if ($depth -eq 0 -and $cleaned -match '^\s*global\s+(.+)') {
            $declContent = $Matches[1]

            # Split on commas, respecting nested parens/brackets
            $parenDepth = 0
            $parts = [System.Collections.ArrayList]::new()
            $current = [System.Text.StringBuilder]::new()
            foreach ($ch in $declContent.ToCharArray()) {
                if ($ch -eq '(' -or $ch -eq '[') { $parenDepth++ }
                elseif ($ch -eq ')' -or $ch -eq ']') { if ($parenDepth -gt 0) { $parenDepth-- } }
                if ($ch -eq ',' -and $parenDepth -eq 0) {
                    [void]$parts.Add($current.ToString())
                    [void]$current.Clear()
                } else {
                    [void]$current.Append($ch)
                }
            }
            [void]$parts.Add($current.ToString())

            foreach ($part in $parts) {
                $trimmed = $part.Trim()
                if ($trimmed -match '^(\w+)\s*:=') {
                    $varName = $Matches[1]
                    if (-not $idGlobalsWithDefaults.ContainsKey($varName)) {
                        $idGlobalsWithDefaults[$varName] = @{
                            Name = $varName
                            File = $relPath
                            Line = ($i + 1)
                        }
                    }
                }
            }
        }

        $depth += $ld.Braces[0] - $ld.Braces[1]
        if ($depth -lt 0) { $depth = 0 }
    }
}

# Phase 2: Find IsSet(VarName) calls where VarName has a default
$idIssues = [System.Collections.ArrayList]::new()
$idIssetCallCount = 0

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]

        # Quick pre-filter
        if (-not $raw.Contains('IsSet')) { continue }
        if ($raw -match ';\s*lint-ignore:\s*isset-with-default') { continue }

        $cleaned = BS_CleanLine $raw
        if ($cleaned -eq '') { continue }

        $regexMatches = [regex]::Matches($cleaned, '\bIsSet\(\s*(\w+)\s*\)')
        foreach ($m in $regexMatches) {
            $idIssetCallCount++
            $varName = $m.Groups[1].Value

            if ($idGlobalsWithDefaults.ContainsKey($varName)) {
                $declInfo = $idGlobalsWithDefaults[$varName]
                # Only flag when declaration is in the SAME file as the IsSet() call.
                # Cross-file declarations may not be loaded at runtime (standalone execution),
                # so IsSet() serves a real purpose there.
                if ($declInfo.File -ne $relPath) { continue }
                [void]$idIssues.Add([PSCustomObject]@{
                    IsSetFile = $relPath
                    IsSetLine = ($i + 1)
                    VarName   = $varName
                    DeclFile  = $declInfo.File
                    DeclLine  = $declInfo.Line
                })
            }
        }
    }
}

if ($idIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($idIssues.Count) IsSet() call(s) on globals with default values.")
    [void]$failOutput.AppendLine("  IsSet() always returns true when the variable has ANY assigned value (including 0, false, `"`").")
    [void]$failOutput.AppendLine("  Fix: declare the global without a value: 'global VarName' (not 'global VarName := 0').")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: isset-with-default' on the IsSet() line.")
    $grouped = $idIssues | Group-Object IsSetFile
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object IsSetLine) {
            [void]$failOutput.AppendLine("      Line $($issue.IsSetLine): IsSet($($issue.VarName)) - always true")
            [void]$failOutput.AppendLine("        declared with default at $($issue.DeclFile):$($issue.DeclLine)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_isset_with_default"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 5: cfg_properties
# Verifies that all cfg.PropertyName accesses match entries in
# the config registry (g: field). Catches typos that would
# silently return "" at runtime.
# Suppress: ; lint-ignore: cfg-property
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$cpIssues = [System.Collections.ArrayList]::new()

# Phase 1: Extract valid property names from config_registry.ahk
$registryFile = @($allFiles | Where-Object { $_.Name -eq 'config_registry.ahk' })
$validCfgProps = [System.Collections.Generic.HashSet[string]]::new()

if ($registryFile.Count -eq 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: config_registry.ahk not found in source directory")
} else {
    $regLines = $fileCache[$registryFile[0].FullName]
    foreach ($line in $regLines) {
        if ($line -match '\bg:\s*"(\w+)"') {
            [void]$validCfgProps.Add($Matches[1])
        }
    }

    # Built-in object methods to skip
    $cfgMethodSkip = [System.Collections.Generic.HashSet[string]]::new()
    @('HasOwnProp', 'DefineProp', 'GetOwnPropDesc', 'OwnProps',
      'HasProp', 'HasMethod', 'GetMethod', '__Class', '__Init',
      'Clone', 'Ptr', 'Base') | ForEach-Object { [void]$cfgMethodSkip.Add($_) }

    # Phase 2: Scan all src/ files for cfg.PropertyName accesses
    foreach ($file in $allFiles) {
        $lines = $fileCache[$file.FullName]

        # Pre-filter: skip files without "cfg."
        $joined = $fileCacheText[$file.FullName]
        if ($joined.IndexOf('cfg.', [System.StringComparison]::Ordinal) -lt 0) { continue }

        $relPath = $file.FullName.Replace("$projectRoot\", '')

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $raw = $lines[$i]
            if ($raw -match '^\s*;') { continue }
            if ($raw -match ';\s*lint-ignore:\s*cfg-property') { continue }
            if ($raw.IndexOf('cfg.', [System.StringComparison]::Ordinal) -lt 0) { continue }

            $cleaned = BS_CleanLine $raw
            if ($cleaned -eq '') { continue }

            # Skip dynamic property access: cfg.%variable%
            if ($cleaned -match 'cfg\.%') { continue }

            $propMatches = [regex]::Matches($cleaned, '\bcfg\.([A-Za-z_]\w*)\b')
            foreach ($m in $propMatches) {
                $prop = $m.Groups[1].Value
                if ($cfgMethodSkip.Contains($prop)) { continue }
                if (-not $validCfgProps.Contains($prop)) {
                    [void]$cpIssues.Add([PSCustomObject]@{
                        File = $relPath; Line = ($i + 1); Property = $prop
                    })
                }
            }
        }
    }
}

if ($cpIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($cpIssues.Count) cfg property access(es) not found in config registry.")
    [void]$failOutput.AppendLine("  cfg.PropertyName silently returns `"`" if the property doesn't exist.")
    [void]$failOutput.AppendLine("  Fix: check spelling against g: field in config_registry.ahk.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: cfg-property' on the access line.")
    $grouped = $cpIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): cfg.$($issue.Property) - not in registry")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_cfg_properties"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 6: duplicate_functions
# Detects function names defined in more than one file.
# In AHK v2 with #Include, the last definition wins silently.
# Suppress: ; lint-ignore: duplicate-function
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dfIssues = [System.Collections.ArrayList]::new()

# Phase 1: Collect file-scope function definitions
$funcDefs = @{}  # funcName -> list of @{ File; Line }

foreach ($file in $allFiles) {
    $processed = $processedCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0

    for ($i = 0; $i -lt $processed.Count; $i++) {
        $ld = $processed[$i]
        if ($ld.Raw -match ';\s*lint-ignore:\s*duplicate-function') {
            # Skip this definition
            if ($ld.Cleaned -ne '') {
                $depth += $ld.Braces[0] - $ld.Braces[1]
            }
            continue
        }

        $cleaned = $ld.Cleaned
        if ($cleaned -eq '') { continue }

        # Only match at file scope (depth == 0)
        if ($depth -eq 0 -and $cleaned -match '^\s*(\w+)\s*\([^)]*\)\s*\{') {
            $funcName = $Matches[1]
            # Skip AHK keywords that look like function defs (if, while, etc.)
            $lower = $funcName.ToLower()
            if ($lower -in @('if', 'else', 'while', 'for', 'loop', 'switch', 'catch',
                'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
                'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
                'new', 'super', 'this', 'true', 'false', 'unset', 'isset')) {
                $depth += $ld.Braces[0] - $ld.Braces[1]
                if ($depth -lt 0) { $depth = 0 }
                continue
            }
            if (-not $funcDefs.ContainsKey($funcName)) {
                $funcDefs[$funcName] = [System.Collections.ArrayList]::new()
            }
            [void]$funcDefs[$funcName].Add(@{ File = $relPath; Line = ($i + 1) })
        }

        $depth += $ld.Braces[0] - $ld.Braces[1]
        if ($depth -lt 0) { $depth = 0 }
    }
}

# Phase 2: Flag any function defined in 2+ files
foreach ($funcName in $funcDefs.Keys | Sort-Object) {
    $defs = $funcDefs[$funcName]
    if ($defs.Count -lt 2) { continue }

    # Check if definitions span multiple files
    $uniqueFiles = @($defs | ForEach-Object { $_.File } | Sort-Object -Unique)
    if ($uniqueFiles.Count -lt 2) { continue }

    [void]$dfIssues.Add([PSCustomObject]@{
        FuncName = $funcName
        Defs     = $defs
    })
}

if ($dfIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($dfIssues.Count) function(s) defined in multiple files.")
    [void]$failOutput.AppendLine("  AHK v2 silently uses the last #Include'd definition - earlier ones are replaced.")
    [void]$failOutput.AppendLine("  Fix: rename one definition, or consolidate into a single file.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: duplicate-function' on the function definition line.")
    foreach ($issue in $dfIssues) {
        [void]$failOutput.AppendLine("    $($issue.FuncName):")
        foreach ($def in $issue.Defs) {
            [void]$failOutput.AppendLine("      $($def.File):$($def.Line)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_duplicate_functions"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 7: fileappend_encoding
# Detects FileAppend() calls without an explicit encoding argument.
# Without encoding, AHK v2 uses the system's ANSI codepage, which
# corrupts Unicode text (window titles, etc.) on non-English systems.
# Suppress: ; lint-ignore: fileappend-encoding
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$faIssues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]

        # Quick pre-filter
        if ($raw.IndexOf('FileAppend(', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($raw -match '^\s*;') { continue }
        if ($raw -match ';\s*lint-ignore:\s*fileappend-encoding') { continue }

        $cleaned = BS_CleanLine $raw
        if ($cleaned -eq '') { continue }

        # Match FileAppend( and extract everything to closing paren
        # Handle multi-line by joining continuation lines
        $callText = $cleaned
        $parenDelta = (BS_CountBraces $cleaned)  # reuse for line info, but need paren count
        $openParens = ($callText.Split('(')).Count - ($callText.Split(')')).Count
        $joinedLineNum = $i
        while ($openParens -gt 0 -and ($joinedLineNum + 1) -lt $lines.Count) {
            $joinedLineNum++
            $nextLine = BS_CleanLine $lines[$joinedLineNum]
            if ($nextLine -eq '') { continue }
            $callText += ' ' + $nextLine
            $openParens = ($callText.Split('(')).Count - ($callText.Split(')')).Count
        }

        # Find FileAppend( call and extract arguments
        if ($callText -match '(?<![.\w])FileAppend\s*\(') {
            $matchPos = $callText.IndexOf('FileAppend')
            $parenStart = $callText.IndexOf('(', $matchPos)
            if ($parenStart -lt 0) { continue }

            # Extract content between matching parens
            $depth = 0; $inStr = $false; $endPos = -1
            for ($ci = $parenStart; $ci -lt $callText.Length; $ci++) {
                $ch = $callText[$ci]
                if ($inStr) { if ($ch -eq '"') { $inStr = $false }; continue }
                if ($ch -eq '"') { $inStr = $true; continue }
                if ($ch -eq '(') { $depth++ }
                elseif ($ch -eq ')') { $depth--; if ($depth -eq 0) { $endPos = $ci; break } }
            }
            if ($endPos -lt 0) { continue }

            $inner = $callText.Substring($parenStart + 1, $endPos - $parenStart - 1)

            # Count top-level commas (arguments) — skip commas inside nested parens/strings
            $argCount = 1; $pd = 0; $inS = $false
            foreach ($ch in $inner.ToCharArray()) {
                if ($inS) { if ($ch -eq '"') { $inS = $false }; continue }
                if ($ch -eq '"') { $inS = $true; continue }
                if ($ch -eq '(' -or $ch -eq '[') { $pd++ }
                elseif ($ch -eq ')' -or $ch -eq ']') { if ($pd -gt 0) { $pd-- } }
                elseif ($ch -eq ',' -and $pd -eq 0) { $argCount++ }
            }

            # FileAppend(text, path) = 2 args (missing encoding)
            # FileAppend(text, path, encoding) = 3 args (OK)
            if ($argCount -eq 2) {
                [void]$faIssues.Add([PSCustomObject]@{
                    File = $relPath; Line = ($i + 1)
                    Text = $raw.Trim()
                })
            }
        }
    }
}

if ($faIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($faIssues.Count) FileAppend() call(s) without explicit encoding.")
    [void]$failOutput.AppendLine("  Without encoding, AHK v2 uses the system ANSI codepage - Unicode text gets corrupted on non-English systems.")
    [void]$failOutput.AppendLine("  Fix: add encoding argument: FileAppend(text, path, `"UTF-8`")")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: fileappend-encoding' on the FileAppend line.")
    $grouped = $faIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Text)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_fileappend_encoding"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 8: lint_ignore_orphans
# Detects ; lint-ignore: <name> comments where <name> is not a
# recognized check name. Catches typos and stale suppressions.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$liIssues = [System.Collections.ArrayList]::new()

# Registry of all valid lint-ignore check names
$validLintNames = [System.Collections.Generic.HashSet[string]]::new()
@(
    'phantom-global',
    'singleinstance', 'winexist-cloaked', 'mixed-returns',
    'critical-leak', 'critical-section',
    'ipc-constant', 'dllcall-types', 'isset-with-default',
    'cfg-property', 'duplicate-function',
    'fileappend-encoding',
    'send-pattern', 'map-dot-access',
    'thememsgbox', 'callback-critical', 'onmessage-collision',
    'postmessage-unsafe', 'callback-signature',
    'static-in-timer', 'timer-lifecycle',
    'dead-function', 'dead-config', 'dead-global', 'dead-local', 'dead-param', 'test-assertions',
    'arity', 'error-boundary',
    'onevent-name', 'destroy-untrack',
    'unreachable-code', 'ipc-symmetry',
    'callback-null-guard', 'setcallbacks-wiring', 'cosmetic-patch-safety',
    'registry-duplicate-key', 'registry-completeness', 'registry-section-casing'
) | ForEach-Object { [void]$validLintNames.Add($_) }

# Scan all src/ and test .ahk files
$testsDir2 = Join-Path $projectRoot "tests"
$lintFiles = @($allFiles)
if (Test-Path $testsDir2) {
    $lintFiles += @(Get-ChildItem -Path $testsDir2 -Filter "*.ahk" -Recurse)
}

foreach ($file in $lintFiles) {
    $lines = if ($fileCache.ContainsKey($file.FullName)) { $fileCache[$file.FullName] }
             else { [System.IO.File]::ReadAllLines($file.FullName) }
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw.IndexOf('lint-ignore:', [System.StringComparison]::Ordinal) -lt 0) { continue }

        # Extract check name(s) from lint-ignore comment
        $lintMatches = [regex]::Matches($raw, 'lint-ignore:\s*([a-zA-Z][a-zA-Z0-9-]*)')
        foreach ($m in $lintMatches) {
            $checkName = $m.Groups[1].Value
            if (-not $validLintNames.Contains($checkName)) {
                [void]$liIssues.Add([PSCustomObject]@{
                    File = $relPath; Line = ($i + 1); Name = $checkName
                })
            }
        }
    }
}

if ($liIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($liIssues.Count) lint-ignore comment(s) with unrecognized check name.")
    [void]$failOutput.AppendLine("  These suppressions have no effect - the check name doesn't match any known check.")
    [void]$failOutput.AppendLine("  Fix: correct the check name spelling, or remove the suppression if no longer needed.")
    [void]$failOutput.AppendLine("  Valid names: $(($validLintNames | Sort-Object) -join ', ')")
    $grouped = $liIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): unknown check '$($issue.Name)'")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_lint_ignore_orphans"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 9: static_in_timers
# Detects static variables used for state tracking inside timer
# callback functions. Static vars leak state if timer is cancelled
# and restarted.
# Suppress: ; lint-ignore: static-in-timer
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$stIssues = [System.Collections.ArrayList]::new()

# Phase 1: Find all SetTimer targets (function names used as callbacks)
$timerCallbacks = @{}  # functionName -> list of "relpath:lineNum"

foreach ($file in $allFiles) {
    # Pre-filter: skip files that don't contain "SetTimer"
    if ($fileCacheText[$file.FullName].IndexOf('SetTimer', [System.StringComparison]::Ordinal) -lt 0) { continue }

    $processed = $processedCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $processed.Count; $i++) {
        $cleaned = $processed[$i].Cleaned
        if ($cleaned -eq '') { continue }

        # Direct function reference: SetTimer(FuncName  or  SetTimer FuncName
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\s*[,\.\)]' -or
            $cleaned -match 'SetTimer\s+([A-Za-z_]\w+)\s*[,]') {
            $funcName = $Matches[1]
            if ($funcName -eq 'ToolTip') { continue }
            if (-not $timerCallbacks.ContainsKey($funcName)) {
                $timerCallbacks[$funcName] = [System.Collections.ArrayList]::new()
            }
            [void]$timerCallbacks[$funcName].Add("${relPath}:$($i + 1)")
        }

        # ObjBindMethod pattern: SetTimer(ObjBindMethod(obj, "MethodName"
        if ($cleaned -match 'SetTimer\(\s*ObjBindMethod\(\s*\w+\s*,\s*"(\w+)"') {
            $methodName = $Matches[1]
            if (-not $timerCallbacks.ContainsKey($methodName)) {
                $timerCallbacks[$methodName] = [System.Collections.ArrayList]::new()
            }
            [void]$timerCallbacks[$methodName].Add("${relPath}:$($i + 1)")
        }

        # .Bind() pattern: SetTimer(FuncName.Bind(
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\.Bind\(') {
            $funcName = $Matches[1]
            if (-not $timerCallbacks.ContainsKey($funcName)) {
                $timerCallbacks[$funcName] = [System.Collections.ArrayList]::new()
            }
            [void]$timerCallbacks[$funcName].Add("${relPath}:$($i + 1)")
        }
    }
}

# Phase 2: For each timer callback, find static variable declarations
$stFunctionsScanned = 0

foreach ($file in $allFiles) {
    # Pre-filter: skip files without any timer callback function name
    if ($timerCallbacks.Count -gt 0) {
        $joined = $fileCacheText[$file.FullName]
        $hasCallback = $false
        foreach ($cbName in $timerCallbacks.Keys) {
            if ($joined.IndexOf($cbName) -ge 0) { $hasCallback = $true; break }
        }
        if (-not $hasCallback) { continue }
    }

    $processed = $processedCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""

    for ($i = 0; $i -lt $processed.Count; $i++) {
        $ld = $processed[$i]
        $cleaned = $ld.Cleaned

        if (-not $inFunc -and $cleaned -ne '' -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if ($fname.ToLower() -notin $BS_AHK_KEYWORDS -and $cleaned -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcDepth = $depth
                $stFunctionsScanned++
            }
        }

        $depth += $ld.Braces[0] - $ld.Braces[1]

        if ($inFunc) {
            if ($timerCallbacks.ContainsKey($funcName) -and $cleaned -ne '') {
                if ($cleaned -match '^\s*static\s+(.+)') {
                    $staticContent = $Matches[1]
                    $rawLine = $ld.Raw

                    if ($rawLine -match 'lint-ignore:\s*static-in-timer') {
                        # Suppressed
                    } else {
                        # Parse each variable in the static declaration
                        $parenDepth = 0
                        $parts = [System.Collections.ArrayList]::new()
                        $current = [System.Text.StringBuilder]::new()
                        foreach ($c in $staticContent.ToCharArray()) {
                            if ($c -eq '(' -or $c -eq '[') { $parenDepth++ }
                            elseif ($c -eq ')' -or $c -eq ']') { if ($parenDepth -gt 0) { $parenDepth-- } }
                            if ($c -eq ',' -and $parenDepth -eq 0) {
                                [void]$parts.Add($current.ToString())
                                $current = [System.Text.StringBuilder]::new()
                            } else {
                                [void]$current.Append($c)
                            }
                        }
                        [void]$parts.Add($current.ToString())

                        foreach ($part in $parts) {
                            $trimmed = $part.Trim()
                            if ($trimmed -match '^(\w+)(.*)$') {
                                $varName = $Matches[1]
                                $rest = $Matches[2].Trim()

                                # Exclusion: Buffer() allocations for DllCall marshalling
                                if ($rest -match '^:=\s*Buffer\(') { continue }

                                # Exclusion: static var := 0 (numeric zero init for DllCall marshal)
                                if ($rest -match '^:=\s*0\s*$') { continue }

                                [void]$stIssues.Add([PSCustomObject]@{
                                    File         = $relPath
                                    Function     = $funcName
                                    Line         = ($i + 1)
                                    Variable     = $varName
                                    SetTimerRefs = $timerCallbacks[$funcName]
                                })
                            }
                        }
                    }
                }
            }

            if ($depth -le $funcDepth) {
                $inFunc = $false
                $funcDepth = -1
            }
        }
    }
}

if ($stIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($stIssues.Count) static variable(s) in timer callback(s) found.")
    [void]$failOutput.AppendLine("  Static vars in timer callbacks can leak state if the timer is cancelled and restarted.")
    [void]$failOutput.AppendLine("  Fix: use tick-based timing with globals instead of static counters.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: static-in-timer' on the static declaration line.")
    $grouped = $stIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Function)() has static var '$($issue.Variable)'")
            foreach ($ref in $issue.SetTimerRefs) {
                [void]$failOutput.AppendLine("        (SetTimer at $ref)")
            }
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_static_in_timers"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 10: timer_lifecycle
# Verifies every repeating SetTimer(callback, positive) has a
# corresponding SetTimer(callback, 0) cancellation in the same file.
# Negative periods (run-once timers) are exempt.
# Suppress: ; lint-ignore: timer-lifecycle
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$TL_SUPPRESSION = 'lint-ignore: timer-lifecycle'
$bindIdentityIssues = [System.Collections.ArrayList]::new()

# Pre-compile regex patterns for timer_lifecycle (used across 3 phases on every line)
$rxTL_Direct     = [regex]::new('SetTimer\(\s*([A-Za-z_]\w+)\s*,\s*(.+?)\s*\)', 'Compiled')
$rxTL_Bind       = [regex]::new('SetTimer\(\s*([A-Za-z_]\w+)\.Bind\(.*?\)\s*,\s*(.+?)\s*\)', 'Compiled')
$rxTL_ArrowPre   = [regex]::new('SetTimer\(\s*\(', 'Compiled')
$rxTL_Arrow      = [regex]::new('SetTimer\(\s*\(.*?\)\s*=>.*?,\s*(.+?)\s*\)', 'Compiled')
$rxTL_BoundVar   = [regex]::new('(\w+)\s*:=\s*([A-Za-z_]\w+)\.Bind\(', 'Compiled')
$rxTL_Cancel     = [regex]::new('SetTimer\(\s*(\w+)\s*,\s*0\s*\)', 'Compiled')
$rxTL_NegPeriod  = [regex]::new('^-', 'Compiled')
$rxTL_PosDigits  = [regex]::new('^\d+$', 'Compiled')
$rxTL_NegDigits  = [regex]::new('^-\d+$', 'Compiled')
$rxTL_AnyReg     = [regex]::new('SetTimer\(\s*([A-Za-z_]\w+)\s*,', 'Compiled')
$rxTL_VarAssign  = [regex]::new('(\w+)\s*:=\s*([A-Za-z_]\w+)\s*$', 'Compiled')
$rxTL_FuncDef    = [regex]::new('^([A-Za-z_]\w+)\s*\(', 'Compiled')

# Phase 1: Collect all SetTimer starts and cancellations per file
$fileTimerData = @{}

foreach ($file in $allFiles) {
    $processed = $processedCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $starts = @{}    # callbackName -> list of line numbers
    $cancels = [System.Collections.Generic.HashSet[string]]::new()
    $boundVars = @{}  # varName -> callbackBaseName

    for ($i = 0; $i -lt $processed.Count; $i++) {
        $ld = $processed[$i]
        $cleaned = $ld.Cleaned
        if ($cleaned -eq '') { continue }

        if ($ld.Raw.Contains($TL_SUPPRESSION)) { continue }

        # Pattern 1: SetTimer(FuncName, period) - direct function reference
        $m1 = $rxTL_Direct.Match($cleaned)
        if ($m1.Success) {
            $cbName = $m1.Groups[1].Value
            $periodStr = $m1.Groups[2].Value.Trim()

            if ($periodStr -eq '0') {
                [void]$cancels.Add($cbName)
                continue
            }
            if ($rxTL_NegPeriod.IsMatch($periodStr)) { continue }

            if (-not $starts.ContainsKey($cbName)) {
                $starts[$cbName] = [System.Collections.ArrayList]::new()
            }
            [void]$starts[$cbName].Add($i + 1)
        }

        # Pattern 2: SetTimer(FuncName.Bind(...), period)
        $m2 = $rxTL_Bind.Match($cleaned)
        if ($m2.Success) {
            $cbName = $m2.Groups[1].Value
            $periodStr = $m2.Groups[2].Value.Trim()

            if ($periodStr -eq '0') {
                [void]$cancels.Add($cbName)
                continue
            }
            if ($rxTL_NegPeriod.IsMatch($periodStr)) { continue }

            # Bind identity check: inline .Bind() with positive period creates
            # an uncancellable repeating timer (each .Bind() creates a new object).
            # Correct pattern: store bound ref in a variable first.
            if ($rxTL_PosDigits.IsMatch($periodStr) -and [int]$periodStr -gt 0) {
                [void]$bindIdentityIssues.Add([PSCustomObject]@{
                    File     = $relPath
                    Line     = ($i + 1)
                    Callback = $cbName
                    Period   = $periodStr
                })
            }

            if (-not $starts.ContainsKey($cbName)) {
                $starts[$cbName] = [System.Collections.ArrayList]::new()
            }
            [void]$starts[$cbName].Add($i + 1)
        }

        # Pattern 2b: SetTimer(() => ..., period) - arrow function (uncancellable)
        # Arrow functions create a new object each call, same problem as inline .Bind().
        if ($rxTL_ArrowPre.IsMatch($cleaned) -and $cleaned.Contains('=>')) {
            $mArr = $rxTL_Arrow.Match($cleaned)
            if ($mArr.Success) {
                $periodStr = $mArr.Groups[1].Value.Trim()
                if ($periodStr -ne '0' -and -not $rxTL_NegPeriod.IsMatch($periodStr) -and $rxTL_PosDigits.IsMatch($periodStr) -and [int]$periodStr -gt 0) {
                    [void]$bindIdentityIssues.Add([PSCustomObject]@{
                        File     = $relPath
                        Line     = ($i + 1)
                        Callback = '() =>'
                        Period   = $periodStr
                    })
                }
            }
        }

        # Pattern 3: varName := FuncName.Bind(...) - track bound variable
        $m3 = $rxTL_BoundVar.Match($cleaned)
        if ($m3.Success) {
            $varName = $m3.Groups[1].Value
            $baseName = $m3.Groups[2].Value
            $boundVars[$varName] = $baseName
        }

        # Pattern 4: SetTimer(varName, period) - variable holding a bound ref
        $m4 = $rxTL_Direct.Match($cleaned)
        if ($m4.Success) {
            $varName = $m4.Groups[1].Value
            $periodStr = $m4.Groups[2].Value.Trim()

            if ($boundVars.ContainsKey($varName)) {
                $baseName = $boundVars[$varName]
                if ($periodStr -eq '0') {
                    [void]$cancels.Add($baseName)
                    [void]$cancels.Add($varName)
                } elseif (-not $rxTL_NegDigits.IsMatch($periodStr)) {
                    if (-not $starts.ContainsKey($baseName)) {
                        $starts[$baseName] = [System.Collections.ArrayList]::new()
                    }
                    $lineNum = $i + 1
                    if (-not $starts[$baseName].Contains($lineNum)) {
                        [void]$starts[$baseName].Add($lineNum)
                    }
                }
            }
        }

        # Pattern 5: SetTimer(varName, 0) - cancellation via variable
        $m5 = $rxTL_Cancel.Match($cleaned)
        if ($m5.Success) {
            $varName = $m5.Groups[1].Value
            [void]$cancels.Add($varName)
            if ($boundVars.ContainsKey($varName)) {
                [void]$cancels.Add($boundVars[$varName])
            }
        }
    }

    if ($starts.Count -gt 0) {
        $fileTimerData[$relPath] = @{
            Starts  = $starts
            Cancels = $cancels
        }
    }
}

# Phase 2: Find starts without corresponding cancellations
$tlIssues = [System.Collections.ArrayList]::new()
$totalStarts = 0
$totalPaired = 0

foreach ($relPath in $fileTimerData.Keys | Sort-Object) {
    $data = $fileTimerData[$relPath]
    $starts = $data.Starts
    $cancels = $data.Cancels

    foreach ($cbName in $starts.Keys) {
        $totalStarts += $starts[$cbName].Count

        if ($cancels.Contains($cbName)) {
            $totalPaired += $starts[$cbName].Count
            continue
        }

        foreach ($lineNum in $starts[$cbName]) {
            [void]$tlIssues.Add([PSCustomObject]@{
                File     = $relPath
                Line     = $lineNum
                Callback = $cbName
            })
        }
    }
}

if ($tlIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($tlIssues.Count) repeating timer(s) without cancellation found.")
    [void]$failOutput.AppendLine("  Every SetTimer(fn, positive) needs a SetTimer(fn, 0) in the same file.")
    [void]$failOutput.AppendLine("  Fix: add SetTimer(callback, 0) in cleanup/exit/stop paths.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: timer-lifecycle' on the SetTimer line.")
    $grouped = $tlIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): SetTimer($($issue.Callback), ...) - no cancellation found")
        }
    }
}

# Phase 3: Cross-file dead cancel detection
# Find SetTimer(fn, 0) where fn is never registered (SetTimer(fn, ...)) in ANY file
# AND fn is not a known function definition or bound variable.
# This catches renamed/removed timer callbacks whose cancellation is now a no-op.
$allRegistered = [System.Collections.Generic.HashSet[string]]::new()
$allBoundVars = [System.Collections.Generic.HashSet[string]]::new()
$allFuncDefs = [System.Collections.Generic.HashSet[string]]::new()
$allCancels = [System.Collections.ArrayList]::new()

# Collect all registrations (positive AND negative periods) across all files
foreach ($relPath in $fileTimerData.Keys) {
    $data = $fileTimerData[$relPath]
    foreach ($cbName in $data.Starts.Keys) {
        [void]$allRegistered.Add($cbName)
    }
}

foreach ($file in $allFiles) {
    $processed = $processedCache[$file.FullName]
    for ($i = 0; $i -lt $processed.Count; $i++) {
        $cleaned = $processed[$i].Cleaned
        if ($cleaned -eq '') { continue }
        # Any SetTimer registration (positive or negative period) — ignore lint-ignore
        # because Phase 3 checks existence, not same-file balance
        $mReg = $rxTL_AnyReg.Match($cleaned)
        if ($mReg.Success) {
            $regName = $mReg.Groups[1].Value
            if (-not $rxTL_Cancel.IsMatch($cleaned)) {
                [void]$allRegistered.Add($regName)
            }
        }
        # Bound variable assignments: varName := FuncName.Bind(...)
        $mBV = $rxTL_BoundVar.Match($cleaned)
        if ($mBV.Success) {
            [void]$allBoundVars.Add($mBV.Groups[1].Value)
        }
        # Direct function ref stored in variable: varName := FuncName (no parens)
        $mVA = $rxTL_VarAssign.Match($cleaned)
        if ($mVA.Success) {
            [void]$allBoundVars.Add($mVA.Groups[1].Value)
        }
        # Function definitions: FuncName(params) {
        $mFD = $rxTL_FuncDef.Match($cleaned)
        if ($mFD.Success) {
            [void]$allFuncDefs.Add($mFD.Groups[1].Value)
        }
    }
}

# Collect all cancellations across all files
foreach ($file in $allFiles) {
    $processed = $processedCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    for ($i = 0; $i -lt $processed.Count; $i++) {
        $cleaned = $processed[$i].Cleaned
        if ($cleaned -eq '') { continue }
        if ($processed[$i].Raw.Contains($TL_SUPPRESSION)) { continue }
        $mCancel = $rxTL_Cancel.Match($cleaned)
        if ($mCancel.Success) {
            $cbName = $mCancel.Groups[1].Value
            [void]$allCancels.Add([PSCustomObject]@{
                File = $relPath; Line = ($i + 1); Callback = $cbName
            })
        }
    }
}

$deadCancelIssues = [System.Collections.ArrayList]::new()
foreach ($cancel in $allCancels) {
    $cb = $cancel.Callback
    # Known via any registration (positive or one-shot)
    if ($allRegistered.Contains($cb)) { continue }
    # Known bound variable (stores a .Bind() ref)
    if ($allBoundVars.Contains($cb)) { continue }
    # Known function definition (may be registered dynamically)
    if ($allFuncDefs.Contains($cb)) { continue }
    [void]$deadCancelIssues.Add($cancel)
}

if ($deadCancelIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($deadCancelIssues.Count) dead timer cancellation(s) found.")
    [void]$failOutput.AppendLine("  SetTimer(fn, 0) where fn is not a known function, bound variable, or registered timer.")
    [void]$failOutput.AppendLine("  This means the callback was renamed or removed but the cancel is now a no-op.")
    [void]$failOutput.AppendLine("  Fix: remove the dead SetTimer(fn, 0) or fix the callback name.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: timer-lifecycle' on the SetTimer line.")
    $grouped = $deadCancelIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): SetTimer($($issue.Callback), 0) - callback never registered")
        }
    }
}

if ($bindIdentityIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($bindIdentityIssues.Count) repeating timer(s) with inline .Bind() or arrow function found.")
    [void]$failOutput.AppendLine("  Each .Bind()/arrow creates a new object, so SetTimer(fn.Bind(x), 0) won't cancel")
    [void]$failOutput.AppendLine("  a timer started with SetTimer(fn.Bind(x), period) - different objects.")
    [void]$failOutput.AppendLine("  Fix: store the bound ref in a variable first:")
    [void]$failOutput.AppendLine("    boundRef := Func.Bind(args)")
    [void]$failOutput.AppendLine("    SetTimer(boundRef, period)")
    [void]$failOutput.AppendLine("    SetTimer(boundRef, 0)  ; same object - cancellation works")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: timer-lifecycle' on the SetTimer line.")
    $grouped = $bindIdentityIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            if ($issue.Callback -eq '() =>') {
                [void]$failOutput.AppendLine("      Line $($issue.Line): SetTimer(() => ..., $($issue.Period)) - arrow function creates uncancellable timer")
            } else {
                [void]$failOutput.AppendLine("      Line $($issue.Line): SetTimer($($issue.Callback).Bind(...), $($issue.Period)) - inline .Bind() creates uncancellable timer")
            }
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_timer_lifecycle"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 11: dead_config
# Detects config registry entries that are never accessed via
# cfg.PropertyName. These are dead entries that can be removed.
# Handles dynamic access (cfg.%expr%) by extracting string literal
# prefixes from files that use dynamic property access.
# Suppress: ; lint-ignore: dead-config
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dcfgIssues = [System.Collections.ArrayList]::new()

# Phase 1: Find all literal cfg.PropertyName accesses across src/ files
$dcfgAccessedKeys = [System.Collections.Generic.HashSet[string]]::new()

foreach ($file in $allFiles) {
    if ($file.Name -eq 'config_registry.ahk') { continue }
    $text = $fileCacheText[$file.FullName]
    if ($text.IndexOf('cfg.', [System.StringComparison]::Ordinal) -lt 0) { continue }

    $cfgMatches = [regex]::Matches($text, '\bcfg\.([A-Za-z_]\w*)')
    foreach ($m in $cfgMatches) {
        [void]$dcfgAccessedKeys.Add($m.Groups[1].Value)
    }
}

# Also scan test files (tests may access cfg.PropertyName)
$dcfgTestsDir = Join-Path $projectRoot "tests"
if (Test-Path $dcfgTestsDir) {
    foreach ($file in @(Get-ChildItem -Path $dcfgTestsDir -Filter "*.ahk" -Recurse)) {
        $text = if ($fileCacheText.ContainsKey($file.FullName)) { $fileCacheText[$file.FullName] }
                else { [System.IO.File]::ReadAllText($file.FullName) }
        if ($text.IndexOf('cfg.', [System.StringComparison]::Ordinal) -lt 0) { continue }
        $cfgMatches = [regex]::Matches($text, '\bcfg\.([A-Za-z_]\w*)')
        foreach ($m in $cfgMatches) {
            [void]$dcfgAccessedKeys.Add($m.Groups[1].Value)
        }
    }
}

# Phase 2: Detect dynamic cfg.% access patterns
# Collect quoted string literals from files that use cfg.%expr% (excluding
# config infrastructure). These strings may be prefixes used to construct
# config key names dynamically (e.g., "Theme_Dark" + suffix → Theme_DarkBg).
$dcfgDynPrefixes = [System.Collections.Generic.HashSet[string]]::new()

foreach ($file in $allFiles) {
    if ($file.Name -eq 'config_registry.ahk' -or $file.Name -eq 'config_loader.ahk') { continue }
    $text = $fileCacheText[$file.FullName]
    if ($text.IndexOf('cfg.%', [System.StringComparison]::Ordinal) -lt 0) { continue }

    # Extract quoted strings (length >= 5) as potential dynamic prefixes
    $strMatches = [regex]::Matches($text, '"([A-Za-z_]\w{4,})"')
    foreach ($m in $strMatches) {
        [void]$dcfgDynPrefixes.Add($m.Groups[1].Value)
    }
}

# Phase 3: Check for lint-ignore suppression on registry entries
$dcfgSuppressed = [System.Collections.Generic.HashSet[string]]::new()
if ($registryFile.Count -gt 0) {
    $regLines = $fileCache[$registryFile[0].FullName]
    for ($ri = 0; $ri -lt $regLines.Count; $ri++) {
        $regLine = $regLines[$ri]
        if ($regLine.IndexOf('lint-ignore:', [System.StringComparison]::Ordinal) -lt 0) { continue }
        if ($regLine -notmatch 'lint-ignore:\s*dead-config') { continue }
        # Find g: "KeyName" on this line or adjacent lines (within same entry)
        for ($rj = [Math]::Max(0, $ri - 2); $rj -le [Math]::Min($regLines.Count - 1, $ri + 2); $rj++) {
            if ($regLines[$rj] -match 'g:\s*"(\w+)"') {
                [void]$dcfgSuppressed.Add($Matches[1])
            }
        }
    }
}

# Phase 4: Find dead keys
foreach ($key in $validCfgProps) {
    if ($dcfgAccessedKeys.Contains($key)) { continue }
    if ($dcfgSuppressed.Contains($key)) { continue }

    # Check if key could be dynamically accessed via prefix matching
    # (e.g., key "Theme_DarkBg" starts with prefix "Theme_Dark" from a cfg.% file)
    $isDynamic = $false
    foreach ($prefix in $dcfgDynPrefixes) {
        if ($key.StartsWith($prefix)) {
            $isDynamic = $true
            break
        }
    }
    if ($isDynamic) { continue }

    [void]$dcfgIssues.Add($key)
}

if ($dcfgIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($dcfgIssues.Count) dead config registry entry(ies).")
    [void]$failOutput.AppendLine("  Keys defined in the registry but never accessed via cfg.PropertyName.")
    [void]$failOutput.AppendLine("  Fix: remove the entry from config_registry.ahk.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: dead-config' on the registry entry line.")
    foreach ($key in $dcfgIssues | Sort-Object) {
        [void]$failOutput.AppendLine("    $key")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_dead_config"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 12: dead_globals
# Detects file-scope global declarations that are never referenced
# outside their declaring file. These are dead globals that can
# be removed.
# Suppress: ; lint-ignore: dead-global
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dgIssues = [System.Collections.ArrayList]::new()

# Phase 1: Collect ALL file-scope global declarations from src/ files
$dgAllGlobals = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $processed = $processedCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0

    for ($i = 0; $i -lt $processed.Count; $i++) {
        $ld = $processed[$i]
        $cleaned = $ld.Cleaned
        if ($cleaned -eq '') { continue }

        # Only look at file-scope (depth == 0) global declarations
        if ($depth -eq 0 -and $cleaned -match '^\s*global\s+(.+)') {
            # Check for lint-ignore suppression
            if ($ld.Raw -match 'lint-ignore:\s*dead-global') {
                $depth += $ld.Braces[0] - $ld.Braces[1]
                if ($depth -lt 0) { $depth = 0 }
                continue
            }

            $declContent = $Matches[1]

            # Split on commas, respecting nested parens/brackets
            $dgParenDepth = 0
            $dgParts = [System.Collections.ArrayList]::new()
            $dgCurrent = [System.Text.StringBuilder]::new()
            foreach ($ch in $declContent.ToCharArray()) {
                if ($ch -eq '(' -or $ch -eq '[') { $dgParenDepth++ }
                elseif ($ch -eq ')' -or $ch -eq ']') { if ($dgParenDepth -gt 0) { $dgParenDepth-- } }
                if ($ch -eq ',' -and $dgParenDepth -eq 0) {
                    [void]$dgParts.Add($dgCurrent.ToString())
                    [void]$dgCurrent.Clear()
                } else {
                    [void]$dgCurrent.Append($ch)
                }
            }
            [void]$dgParts.Add($dgCurrent.ToString())

            foreach ($part in $dgParts) {
                $trimmed = $part.Trim()
                if ($trimmed -match '^(\w+)') {
                    $varName = $Matches[1]
                    [void]$dgAllGlobals.Add(@{
                        Name = $varName
                        File = $relPath
                        Line = ($i + 1)
                        FullPath = $file.FullName
                    })
                }
            }
        }

        $depth += $ld.Braces[0] - $ld.Braces[1]
        if ($depth -lt 0) { $depth = 0 }
    }
}

# Phase 2: Build text cache for test files (src/ already in $fileCacheText)
$dgTestTexts = @{}
$dgTestsDir = Join-Path $projectRoot "tests"
if (Test-Path $dgTestsDir) {
    foreach ($file in @(Get-ChildItem -Path $dgTestsDir -Filter "*.ahk" -Recurse)) {
        if (-not $fileCacheText.ContainsKey($file.FullName)) {
            $dgTestTexts[$file.FullName] = [System.IO.File]::ReadAllText($file.FullName)
        }
    }
}

# Phase 3: For each global, check if it appears in any file OTHER than its declaring file.
# For globals only in their declaring file, check if they have any reads (not just writes).
# A global is "dead" if it has no external references AND no reads within its declaring file
# (only declarations, global access statements, and pure assignments like VarName := expr).
foreach ($g in $dgAllGlobals) {
    $varName = $g.Name
    $declFullPath = $g.FullPath
    $foundElsewhere = $false

    # Check all src/ files (excluding declaring file)
    foreach ($f in $allFiles) {
        if ($f.FullName -eq $declFullPath) { continue }
        if ($fileCacheText[$f.FullName].IndexOf($varName, [System.StringComparison]::Ordinal) -ge 0) {
            $foundElsewhere = $true
            break
        }
    }

    # Check test files if not found in src/
    if (-not $foundElsewhere) {
        foreach ($kv in $dgTestTexts.GetEnumerator()) {
            if ($kv.Value.IndexOf($varName, [System.StringComparison]::Ordinal) -ge 0) {
                $foundElsewhere = $true
                break
            }
        }
    }

    if ($foundElsewhere) { continue }

    # Global only in declaring file — check if it has any reads (not just writes).
    # A line is a "read" if VarName appears on a non-global, non-assignment line.
    # This catches write-only globals (declared + assigned but never consumed).
    $hasRead = $false
    $dgLines = $fileCache[$declFullPath]
    $escapedName = [regex]::Escape($varName)

    for ($li = 0; $li -lt $dgLines.Count; $li++) {
        $dgRaw = $dgLines[$li]
        if ($dgRaw.IndexOf($varName, [System.StringComparison]::Ordinal) -lt 0) { continue }

        $dgCleaned = BS_CleanLine $dgRaw
        if ($dgCleaned -eq '') { continue }

        # Skip global declaration/access lines (global VarName ... at any depth)
        if ($dgCleaned -match '^\s*global\b') { continue }

        # Skip pure assignment lines: VarName := expr (VarName is the LHS target)
        if ($dgCleaned -match "^\s*$escapedName\s*:=") { continue }

        # Any other occurrence means VarName is being read (used as value, passed to
        # function, indexed, iterated, compared, etc.)
        $hasRead = $true
        break
    }

    if (-not $hasRead) {
        [void]$dgIssues.Add([PSCustomObject]@{
            Name = $varName
            File = $g.File
            Line = $g.Line
        })
    }
}

if ($dgIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($dgIssues.Count) dead global(s) found.")
    [void]$failOutput.AppendLine("  Global declared at file scope but never referenced outside its file, and write-only within it.")
    [void]$failOutput.AppendLine("  Fix: remove the global declaration if unused, or move it to local scope.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: dead-global' on the declaration line.")
    $grouped = $dgIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Name)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_dead_globals"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# === Shared: Extract function definitions for sub-checks 13-14 ===
# Parses file-scope function defs: name, param string, body range.
$bsFuncDefs = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $bfProc = $processedCache[$file.FullName]
    $bfRel = $file.FullName.Replace("$projectRoot\", '')
    $bfDepth = 0
    $bfInFunc = $false
    $bfPending = $false
    $bfName = ''; $bfParams = ''; $bfDefIdx = 0; $bfStartLine = 0

    for ($bfi = 0; $bfi -lt $bfProc.Count; $bfi++) {
        $bfLd = $bfProc[$bfi]
        $bfCl = $bfLd.Cleaned
        if ($bfCl -eq '') { continue }
        $bfO = $bfLd.Braces[0]; $bfC = $bfLd.Braces[1]

        if (-not $bfInFunc -and -not $bfPending -and $bfDepth -eq 0) {
            if ($bfCl -match '^\s*(\w+)\s*\(') {
                $bfCandName = $Matches[1]
                if ($bfCandName -notin $BS_AHK_KEYWORDS) {
                    # Extract param string with paren matching
                    $bfPS = $bfCl.IndexOf('(')
                    $bfPD = 0; $bfPE = -1
                    for ($bfci = $bfPS; $bfci -lt $bfCl.Length; $bfci++) {
                        if ($bfCl[$bfci] -eq '(') { $bfPD++ }
                        elseif ($bfCl[$bfci] -eq ')') { $bfPD--; if ($bfPD -eq 0) { $bfPE = $bfci; break } }
                    }
                    if ($bfPE -gt $bfPS) {
                        $bfName = $bfCandName
                        $bfParams = $bfCl.Substring($bfPS + 1, $bfPE - $bfPS - 1)
                        $bfStartLine = $bfi + 1
                        $bfDefIdx = $bfi
                        if ($bfO -gt 0) {
                            $bfInFunc = $true
                            $bfDepth += $bfO - $bfC
                            if ($bfDepth -le 0) {
                                [void]$bsFuncDefs.Add(@{
                                    Name = $bfName; Params = $bfParams; DefIdx = $bfDefIdx
                                    EndIdx = $bfi; File = $bfRel; FullPath = $file.FullName
                                    StartLine = $bfStartLine
                                })
                                $bfInFunc = $false; $bfDepth = 0
                            }
                        } else {
                            $bfPending = $true
                        }
                        continue
                    }
                }
            }
        }

        if ($bfPending) {
            if ($bfO -gt 0) {
                $bfInFunc = $true
                $bfPending = $false
                $bfDepth += $bfO - $bfC
                if ($bfDepth -le 0) {
                    [void]$bsFuncDefs.Add(@{
                        Name = $bfName; Params = $bfParams; DefIdx = $bfDefIdx
                        EndIdx = $bfi; File = $bfRel; FullPath = $file.FullName
                        StartLine = $bfStartLine
                    })
                    $bfInFunc = $false; $bfDepth = 0
                }
            } else {
                $bfPending = $false
                $bfDepth += $bfO - $bfC
                if ($bfDepth -lt 0) { $bfDepth = 0 }
            }
            continue
        }

        if ($bfInFunc) {
            $bfDepth += $bfO - $bfC
            if ($bfDepth -le 0) {
                [void]$bsFuncDefs.Add(@{
                    Name = $bfName; Params = $bfParams; DefIdx = $bfDefIdx
                    EndIdx = $bfi; File = $bfRel; FullPath = $file.FullName
                    StartLine = $bfStartLine
                })
                $bfInFunc = $false; $bfDepth = 0
            }
        } else {
            $bfDepth += $bfO - $bfC
            if ($bfDepth -lt 0) { $bfDepth = 0 }
        }
    }
}

# Shared helper: parse param names from a param string
function BS_ParseParamNames {
    param([string]$paramStr)
    $result = @{}
    $ps = $paramStr.Trim()
    if ($ps -eq '' -or $ps -eq '*') { return $result }
    $ppd = 0
    $parts = [System.Collections.ArrayList]::new()
    $buf = [System.Text.StringBuilder]::new()
    foreach ($ch in $ps.ToCharArray()) {
        if ($ch -eq '(' -or $ch -eq '[') { $ppd++ }
        elseif ($ch -eq ')' -or $ch -eq ']') { if ($ppd -gt 0) { $ppd-- } }
        if ($ch -eq ',' -and $ppd -eq 0) {
            [void]$parts.Add($buf.ToString()); [void]$buf.Clear()
        } else { [void]$buf.Append($ch) }
    }
    [void]$parts.Add($buf.ToString())
    foreach ($pp in $parts) {
        $ppt = $pp.Trim()
        if ($ppt -eq '*' -or $ppt.EndsWith('*')) { continue }
        $ppt = $ppt -replace '^(?:ByRef\s+|&)', ''
        if ($ppt -match '^(\w+)') { $result[$Matches[1]] = $true }
    }
    return $result
}

# ============================================================
# Sub-check 13: dead_locals
# Detects local variables inside functions that are assigned but
# never read. Write-only locals are dead code.
# Suppress: ; lint-ignore: dead-local (on assignment or function def line)
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dlIssues = [System.Collections.ArrayList]::new()

foreach ($fd in $bsFuncDefs) {
    $dlProc = $processedCache[$fd.FullPath]
    $dlDefIdx = $fd.DefIdx
    $dlEndIdx = $fd.EndIdx

    # Function-level suppression
    if ($dlProc[$dlDefIdx].Raw -match 'lint-ignore:\s*dead-local') { continue }

    $dlParamNames = BS_ParseParamNames $fd.Params

    # Collect globals, statics, and local assignments within function body
    $dlGlobals = @{}
    $dlStatics = @{}
    $dlLocals = @{}  # varName -> @{ Line = int; Idx = int }

    for ($dli = $dlDefIdx + 1; $dli -lt $dlEndIdx; $dli++) {
        $dlCl = $dlProc[$dli].Cleaned
        if ($dlCl -eq '') { continue }

        # Collect global declarations
        if ($dlCl -match '^\s*global\b\s+(.*)') {
            foreach ($gp in $Matches[1].Split(',')) {
                if ($gp.Trim() -match '^(\w+)') { $dlGlobals[$Matches[1]] = $true }
            }
            continue
        }

        # Collect static declarations
        if ($dlCl -match '^\s*static\b\s+(.*)') {
            foreach ($sp in $Matches[1].Split(',')) {
                if ($sp.Trim() -match '^(\w+)') { $dlStatics[$Matches[1]] = $true }
            }
            continue
        }

        # Collect for-loop variables (two-var form)
        if ($dlCl -match '^\s*for\s+(\w+)\s*,\s*(\w+)\s+in\b') {
            foreach ($fv in @($Matches[1], $Matches[2])) {
                if ($fv -ne '_' -and -not $dlGlobals.ContainsKey($fv) -and
                    -not $dlStatics.ContainsKey($fv) -and -not $dlParamNames.ContainsKey($fv) -and
                    -not $dlLocals.ContainsKey($fv)) {
                    $dlLocals[$fv] = @{ Line = $dli + 1; Idx = $dli }
                }
            }
            continue
        }
        # Collect for-loop variables (single-var form)
        if ($dlCl -match '^\s*for\s+(\w+)\s+in\b') {
            $fv = $Matches[1]
            if ($fv -ne '_' -and -not $dlGlobals.ContainsKey($fv) -and
                -not $dlStatics.ContainsKey($fv) -and -not $dlParamNames.ContainsKey($fv) -and
                -not $dlLocals.ContainsKey($fv)) {
                $dlLocals[$fv] = @{ Line = $dli + 1; Idx = $dli }
            }
            continue
        }

        # Collect catch-as variables
        if ($dlCl -match '^\s*catch\b.*\bas\s+(\w+)') {
            $cv = $Matches[1]
            if ($cv -ne '_' -and -not $dlGlobals.ContainsKey($cv) -and
                -not $dlStatics.ContainsKey($cv) -and -not $dlParamNames.ContainsKey($cv) -and
                -not $dlLocals.ContainsKey($cv)) {
                $dlLocals[$cv] = @{ Line = $dli + 1; Idx = $dli }
            }
        }

        # Collect explicit local declarations: local varName :=
        if ($dlCl -match '^\s*local\s+(\w+)\s*:=') {
            $lv = $Matches[1]
            if ($lv -ne '_' -and -not $dlLocals.ContainsKey($lv)) {
                $dlLocals[$lv] = @{ Line = $dli + 1; Idx = $dli }
            }
            continue
        }

        # Collect implicit local assignments: varName :=
        if ($dlCl -match '^\s*(\w+)\s*:=') {
            $av = $Matches[1]
            if ($null -ne $av -and $av -ne '_' -and $av -notin $BS_AHK_KEYWORDS -and
                -not $av.StartsWith('A_') -and -not $dlLocals.ContainsKey($av)) {
                if (-not $dlGlobals.ContainsKey($av) -and -not $dlStatics.ContainsKey($av) -and
                    -not $dlParamNames.ContainsKey($av)) {
                    $dlLocals[$av] = @{ Line = $dli + 1; Idx = $dli }
                }
            }
        }
    }

    # Check each local for reads in the function body
    foreach ($dlVar in @($dlLocals.Keys)) {
        $dlHasRead = $false
        $dlEsc = [regex]::Escape($dlVar)

        for ($dli = $dlDefIdx + 1; $dli -lt $dlEndIdx; $dli++) {
            $dlCl = $dlProc[$dli].Cleaned
            if ($dlCl -eq '') { continue }
            if ($dlCl.IndexOf($dlVar, [System.StringComparison]::Ordinal) -lt 0) { continue }

            # Skip global/static/local declaration lines
            if ($dlCl -match '^\s*(global|static|local)\b') { continue }

            # Skip pure assignment lines: VarName :=
            if ($dlCl -match "^\s*$dlEsc\s*:=") { continue }

            # Skip for-loop header lines where this var is being defined
            if ($dlCl -match '^\s*for\b') {
                if ($dlCl -match "^\s*for\s+(?:(\w+)\s*,\s*)?(\w+)\s+in\b") {
                    if ($dlVar -eq $Matches[1] -or $dlVar -eq $Matches[2]) { continue }
                }
            }

            # Skip catch-as definition lines for this variable
            if ($dlCl -match "^\s*catch\b.*\bas\s+$dlEsc\b") { continue }

            # Word-bounded occurrence = a read
            if ($dlCl -match "(?<![.\w])$dlEsc(?!\w)") {
                $dlHasRead = $true
                break
            }
        }

        if (-not $dlHasRead) {
            $dlInfo = $dlLocals[$dlVar]
            if ($null -eq $dlInfo) { continue }

            # Fallback: check raw lines for mixed-quote string concatenation
            # (BS_CleanLine can eat variables between alternating quote styles)
            $dlRawHit = $false
            for ($dli = $dlDefIdx + 1; $dli -lt $dlEndIdx; $dli++) {
                if ($dli -eq $dlInfo['Idx']) { continue }  # skip definition line
                $dlRawLine = $dlProc[$dli].Raw
                if ($dlRawLine.IndexOf($dlVar, [System.StringComparison]::Ordinal) -lt 0) { continue }
                $dlRawTrimmed = $dlRawLine.TrimStart()
                if ($dlRawTrimmed.Length -gt 0 -and $dlRawTrimmed[0] -ne ';') {
                    $dlRawHit = $true; break
                }
            }
            if ($dlRawHit) { continue }

            # Check per-line lint-ignore
            $dlRaw = $dlProc[$dlInfo['Idx']].Raw
            if ($dlRaw -match 'lint-ignore:\s*dead-local') { continue }

            [void]$dlIssues.Add([PSCustomObject]@{
                Func = $fd.Name; Var = $dlVar
                File = $fd.File; Line = $dlInfo['Line']
            })
        }
    }
}

if ($dlIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($dlIssues.Count) dead local variable(s) found.")
    [void]$failOutput.AppendLine("  Local variable assigned but never read within its function.")
    [void]$failOutput.AppendLine("  Fix: remove the variable, or use '_' for intentional throwaway.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: dead-local' on assignment or function line.")
    $dlGrouped = $dlIssues | Group-Object File
    foreach ($group in $dlGrouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line) ($($issue.Func)): $($issue.Var)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_dead_locals"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 14: dead_params
# Detects function parameters never referenced in the function
# body. Excludes variadic (*) and throwaway (_).
# Suppress: ; lint-ignore: dead-param (on function definition line)
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dpIssues = [System.Collections.ArrayList]::new()

foreach ($fd in $bsFuncDefs) {
    $dpProc = $processedCache[$fd.FullPath]
    $dpDefIdx = $fd.DefIdx
    $dpEndIdx = $fd.EndIdx

    # Function-level suppression
    if ($dpProc[$dpDefIdx].Raw -match 'lint-ignore:\s*dead-param') { continue }

    $dpParamStr = $fd.Params.Trim()
    if ($dpParamStr -eq '' -or $dpParamStr -eq '*') { continue }

    $dpNames = BS_ParseParamNames $dpParamStr

    foreach ($dpName in @($dpNames.Keys)) {
        if ($dpName -eq '_') { continue }

        $dpFound = $false
        $dpEsc = [regex]::Escape($dpName)

        for ($dpi = $dpDefIdx + 1; $dpi -lt $dpEndIdx; $dpi++) {
            $dpCl = $dpProc[$dpi].Cleaned
            if ($dpCl -eq '') { continue }
            if ($dpCl.IndexOf($dpName, [System.StringComparison]::Ordinal) -lt 0) { continue }
            if ($dpCl -match "(?<![.\w])$dpEsc(?!\w)") {
                $dpFound = $true
                break
            }
        }

        if (-not $dpFound) {
            [void]$dpIssues.Add([PSCustomObject]@{
                Func = $fd.Name; Param = $dpName
                File = $fd.File; Line = $fd.StartLine
            })
        }
    }
}

if ($dpIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($dpIssues.Count) dead parameter(s) found.")
    [void]$failOutput.AppendLine("  Function parameter never referenced in function body.")
    [void]$failOutput.AppendLine("  Fix: remove param, rename to '_', or use it. For callbacks with fixed")
    [void]$failOutput.AppendLine("  signatures, add '; lint-ignore: dead-param' on the function definition line.")
    $dpGrouped = $dpIssues | Group-Object File
    foreach ($group in $dpGrouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line) ($($issue.Func)): $($issue.Param)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_dead_params"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 15: registry_key_uniqueness
# Detects duplicate (section, key) pairs in gConfigRegistry.
# INI format silently allows duplicate keys — IniRead returns
# only the first value, IniWrite appends a duplicate. This has
# caused actual bugs (duplicate keys in [Diagnostics]).
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rkuIssues = [System.Collections.ArrayList]::new()

$rkuRegFile = @($allFiles | Where-Object { $_.Name -eq 'config_registry.ahk' })

if ($rkuRegFile.Count -gt 0) {
    $rkuLines = $fileCache[$rkuRegFile[0].FullName]
    $rkuSeen = @{}  # "Section|Key" -> line number (first occurrence)

    for ($i = 0; $i -lt $rkuLines.Count; $i++) {
        $raw = $rkuLines[$i]
        if ($raw -match '^\s*;') { continue }

        # Match setting entries: {s: "Section", k: "Key", ...}
        if ($raw -match '\bs:\s*"([^"]+)"' -and $raw -match '\bk:\s*"([^"]+)"') {
            $sect = $Matches[0]  # k: match is in $Matches
            # Re-extract both since $Matches only holds the last match
            $null = $raw -match '\bs:\s*"([^"]+)"'
            $sect = $Matches[1]
            $null = $raw -match '\bk:\s*"([^"]+)"'
            $key = $Matches[1]

            $composite = "$sect|$key"
            if ($rkuSeen.ContainsKey($composite)) {
                [void]$rkuIssues.Add([PSCustomObject]@{
                    Section = $sect; Key = $key
                    Line1 = $rkuSeen[$composite]; Line2 = ($i + 1)
                })
            } else {
                $rkuSeen[$composite] = ($i + 1)
            }
        }
    }
}

if ($rkuIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($rkuIssues.Count) duplicate (section, key) pair(s) in config registry.")
    [void]$failOutput.AppendLine("  INI format silently allows duplicate keys - IniRead returns only the first value.")
    [void]$failOutput.AppendLine("  Fix: remove or rename the duplicate entry in config_registry.ahk.")
    foreach ($issue in $rkuIssues) {
        [void]$failOutput.AppendLine("    [$($issue.Section)] $($issue.Key): first at line $($issue.Line1), duplicate at line $($issue.Line2)")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_registry_key_uniqueness"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 16: registry_completeness
# Validates each gConfigRegistry setting entry has all required
# fields and valid constraints:
#   - Required fields: s, k, g, t, default, d
#   - Numeric types (int/float) must have min AND max
#   - g field must be a valid AHK identifier
#   - default must be within [min, max] when both present
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rcIssues = [System.Collections.ArrayList]::new()

if ($rkuRegFile.Count -gt 0) {
    $rcLines = $fileCache[$rkuRegFile[0].FullName]

    # Accumulate multi-line entries: join continuation lines until braces balance
    $rcEntries = [System.Collections.ArrayList]::new()
    $accumLine = ''; $accumStart = -1; $braceDepth = 0

    for ($i = 0; $i -lt $rcLines.Count; $i++) {
        $raw = $rcLines[$i]
        if ($raw -match '^\s*;') { continue }

        # Detect start of an entry: opening { with s: or type:
        if ($accumStart -lt 0) {
            if ($raw -match '\{.*\bs:') {
                $accumLine = $raw; $accumStart = $i
                $braceDepth = ($raw.Split('{')).Count - ($raw.Split('}')).Count
                if ($braceDepth -le 0) {
                    [void]$rcEntries.Add(@{ Text = $accumLine; Line = $accumStart + 1 })
                    $accumLine = ''; $accumStart = -1; $braceDepth = 0
                }
            }
        } else {
            $accumLine += ' ' + $raw
            $braceDepth += ($raw.Split('{')).Count - ($raw.Split('}')).Count
            if ($braceDepth -le 0) {
                [void]$rcEntries.Add(@{ Text = $accumLine; Line = $accumStart + 1 })
                $accumLine = ''; $accumStart = -1; $braceDepth = 0
            }
        }
    }

    foreach ($entry in $rcEntries) {
        $text = $entry.Text
        $lineNum = $entry.Line

        # Skip section/subsection entries (they have type: field, no s:+k: together meaningfully)
        if ($text -match '\btype:\s*"(section|subsection)"') { continue }

        # Extract fields
        $hasS = $text -match '\bs:\s*"[^"]+"'
        $hasK = $text -match '\bk:\s*"[^"]+"'
        $hasG = $text -match '\bg:\s*"([^"]+)"'
        $gValue = if ($hasG) { $Matches[1] } else { '' }
        $hasT = $text -match '\bt:\s*"([^"]+)"'
        $tValue = if ($hasT) { $Matches[1] } else { '' }
        $hasDefault = $text -match '\bdefault:\s*'
        $hasD = $text -match '\bd:\s*"'
        $hasMin = $text -match '\bmin:\s*(-?[\d.]+)'
        $minVal = if ($hasMin) { [double]$Matches[1] } else { 0 }
        $hasMax = $text -match '\bmax:\s*(-?[\d.]+)'
        $maxVal = if ($hasMax) { [double]$Matches[1] } else { 0 }

        # Check required fields
        $missing = @()
        if (-not $hasS) { $missing += 's' }
        if (-not $hasK) { $missing += 'k' }
        if (-not $hasG) { $missing += 'g' }
        if (-not $hasT) { $missing += 't' }
        if (-not $hasDefault) { $missing += 'default' }
        if (-not $hasD) { $missing += 'd' }

        if ($missing.Count -gt 0) {
            [void]$rcIssues.Add([PSCustomObject]@{
                Line = $lineNum; Issue = "missing required field(s): $($missing -join ', ')"
                G = $gValue
            })
        }

        # Validate g field is valid AHK identifier
        if ($hasG -and $gValue -notmatch '^[A-Za-z_]\w*$') {
            [void]$rcIssues.Add([PSCustomObject]@{
                Line = $lineNum; Issue = "g field '$gValue' is not a valid AHK identifier"
                G = $gValue
            })
        }

        # Numeric types must have min AND max
        if ($tValue -eq 'int' -or $tValue -eq 'float') {
            if ($hasMin -ne $hasMax) {
                $which = if ($hasMin) { 'max' } else { 'min' }
                [void]$rcIssues.Add([PSCustomObject]@{
                    Line = $lineNum; Issue = "numeric type '$tValue' has min but missing $which (need both or neither)"
                    G = $gValue
                })
            }
            if (-not $hasMin -and -not $hasMax) {
                [void]$rcIssues.Add([PSCustomObject]@{
                    Line = $lineNum; Issue = "numeric type '$tValue' missing min/max constraints"
                    G = $gValue
                })
            }
        }

        # Default within range
        if ($hasMin -and $hasMax -and $hasDefault) {
            $defaultMatch = $null
            if ($text -match '\bdefault:\s*(-?[\d.]+)') {
                $defaultVal = [double]$Matches[1]
                if ($defaultVal -lt $minVal -or $defaultVal -gt $maxVal) {
                    [void]$rcIssues.Add([PSCustomObject]@{
                        Line = $lineNum; Issue = "default $defaultVal outside range [$minVal, $maxVal]"
                        G = $gValue
                    })
                }
            }
        }
    }
}

if ($rcIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($rcIssues.Count) config registry entry issue(s) found.")
    [void]$failOutput.AppendLine("  Each setting entry needs: s, k, g, t, default, d. Numeric types need min/max.")
    foreach ($issue in $rcIssues) {
        $label = if ($issue.G) { "($($issue.G))" } else { "" }
        [void]$failOutput.AppendLine("    Line $($issue.Line) $label`: $($issue.Issue)")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_registry_completeness"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 17: registry_section_casing
# Detects section names used with inconsistent casing.
# INI sections are case-insensitive in Windows APIs but may
# behave differently in other parsers. Inconsistent casing
# is always unintentional and confusing.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rscIssues = [System.Collections.ArrayList]::new()

if ($rkuRegFile.Count -gt 0) {
    $rscLines = $fileCache[$rkuRegFile[0].FullName]
    $rscSections = @{}  # lowercase -> list of @{ Name; Line }

    for ($i = 0; $i -lt $rscLines.Count; $i++) {
        $raw = $rscLines[$i]
        if ($raw -match '^\s*;') { continue }

        # Match s: "SectionName" in setting entries
        if ($raw -match '\bs:\s*"([^"]+)"') {
            $sectName = $Matches[1]
            $lower = $sectName.ToLower()
            if (-not $rscSections.ContainsKey($lower)) {
                $rscSections[$lower] = [System.Collections.ArrayList]::new()
            }
            # Only add unique casings
            $existing = @($rscSections[$lower] | ForEach-Object { $_.Name })
            if ($sectName -cnotin $existing) {
                [void]$rscSections[$lower].Add(@{ Name = $sectName; Line = ($i + 1) })
            }
        }

        # Also check type: "section" entries for the name: field
        if ($raw -match '\btype:\s*"section"' -and $raw -match '\bname:\s*"([^"]+)"') {
            $sectName = $Matches[1]
            $lower = $sectName.ToLower()
            if (-not $rscSections.ContainsKey($lower)) {
                $rscSections[$lower] = [System.Collections.ArrayList]::new()
            }
            $existing = @($rscSections[$lower] | ForEach-Object { $_.Name })
            if ($sectName -cnotin $existing) {
                [void]$rscSections[$lower].Add(@{ Name = $sectName; Line = ($i + 1) })
            }
        }
    }

    foreach ($lower in $rscSections.Keys) {
        $casings = $rscSections[$lower]
        if ($casings.Count -gt 1) {
            $names = ($casings | ForEach-Object { "'$($_.Name)'" }) -join ', '
            [void]$rscIssues.Add([PSCustomObject]@{
                Section = $lower; Casings = $names
                Lines = ($casings | ForEach-Object { $_.Line }) -join ', '
            })
        }
    }
}

if ($rscIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($rscIssues.Count) section name(s) with inconsistent casing.")
    [void]$failOutput.AppendLine("  INI sections are case-insensitive in Windows - inconsistent casing is confusing.")
    [void]$failOutput.AppendLine("  Fix: use consistent casing for all references to the same section.")
    foreach ($issue in $rscIssues) {
        [void]$failOutput.AppendLine("    Section '$($issue.Section)': found casings $($issue.Casings) (lines $($issue.Lines))")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_registry_section_casing"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All simple checks passed (switch_global, ipc_constants, dllcall_types, isset_with_default, cfg_properties, duplicate_functions, fileappend_encoding, lint_ignore_orphans, static_in_timers, timer_lifecycle, dead_config, dead_globals, dead_locals, dead_params, registry_key_uniqueness, registry_completeness, registry_section_casing)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_simple_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
