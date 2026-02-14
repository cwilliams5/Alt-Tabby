# check_batch_simple.ps1 - Batched simple pattern checks
# Combines 10 lightweight checks into one PowerShell process to reduce startup overhead.
# Sub-checks: switch_global, ipc_constants, dllcall_types, isset_with_default, cfg_properties, duplicate_functions, fileappend_encoding, lint_ignore_orphans, static_in_timers, timer_lifecycle
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
                    # Handle context: type equality comparison
                    if ($rawLine -match "type\s*={1,2}\s*$escapedName\b" -or
                        $rawLine -match "\[.type.\]\s*={1,2}\s*$escapedName\b" -or
                        $rawLine -match "^\s*case\b.*\b$escapedName\b") {
                        [void]$constInHandle.Add($constName)
                    }
                    # Send context: type construction (object literal, Map assignment, string concat)
                    if ($rawLine -match "type:\s*$escapedName\b" -or
                        $rawLine -match "\[.type.\]\s*:=\s*$escapedName\b" -or
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
    'dead-function', 'test-assertions',
    'arity',
    'onevent-name', 'destroy-untrack',
    'unreachable-code', 'ipc-symmetry'
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
    [void]$failOutput.AppendLine("  Valid names: $($validLintNames | Sort-Object | Join-String -Separator ', ')")
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
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\s*,\s*(.+?)\s*\)') {
            $cbName = $Matches[1]
            $periodStr = $Matches[2].Trim()

            if ($periodStr -eq '0') {
                [void]$cancels.Add($cbName)
                continue
            }
            if ($periodStr -match '^-') { continue }

            if (-not $starts.ContainsKey($cbName)) {
                $starts[$cbName] = [System.Collections.ArrayList]::new()
            }
            [void]$starts[$cbName].Add($i + 1)
        }

        # Pattern 2: SetTimer(FuncName.Bind(...), period)
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\.Bind\(.*?\)\s*,\s*(.+?)\s*\)') {
            $cbName = $Matches[1]
            $periodStr = $Matches[2].Trim()

            if ($periodStr -eq '0') {
                [void]$cancels.Add($cbName)
                continue
            }
            if ($periodStr -match '^-') { continue }

            # Bind identity check: inline .Bind() with positive period creates
            # an uncancellable repeating timer (each .Bind() creates a new object).
            # Correct pattern: store bound ref in a variable first.
            if ($periodStr -match '^\d+$' -and [int]$periodStr -gt 0) {
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

        # Pattern 3: varName := FuncName.Bind(...) - track bound variable
        if ($cleaned -match '(\w+)\s*:=\s*([A-Za-z_]\w+)\.Bind\(') {
            $varName = $Matches[1]
            $baseName = $Matches[2]
            $boundVars[$varName] = $baseName
        }

        # Pattern 4: SetTimer(varName, period) - variable holding a bound ref
        if ($cleaned -match 'SetTimer\(\s*([A-Za-z_]\w+)\s*,\s*(.+?)\s*\)') {
            $varName = $Matches[1]
            $periodStr = $Matches[2].Trim()

            if ($boundVars.ContainsKey($varName)) {
                $baseName = $boundVars[$varName]
                if ($periodStr -eq '0') {
                    [void]$cancels.Add($baseName)
                    [void]$cancels.Add($varName)
                } elseif ($periodStr -notmatch '^-\d+$') {
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
        if ($cleaned -match 'SetTimer\(\s*(\w+)\s*,\s*0\s*\)') {
            $varName = $Matches[1]
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

if ($bindIdentityIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($bindIdentityIssues.Count) repeating timer(s) with inline .Bind() found.")
    [void]$failOutput.AppendLine("  Each .Bind() creates a new object, so SetTimer(fn.Bind(x), 0) won't cancel")
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
            [void]$failOutput.AppendLine("      Line $($issue.Line): SetTimer($($issue.Callback).Bind(...), $($issue.Period)) - inline .Bind() creates uncancellable timer")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_timer_lifecycle"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All simple checks passed (switch_global, ipc_constants, dllcall_types, isset_with_default, cfg_properties, duplicate_functions, fileappend_encoding, lint_ignore_orphans, static_in_timers, timer_lifecycle)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_simple_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
