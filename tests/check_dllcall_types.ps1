# check_dllcall_types.ps1 - Static analysis for DllCall handle type mismatches
# Pre-gate test: runs before any AHK process launches.
# Catches 32-bit types (Int/UInt) used for handle/pointer values in DllCall.
# On 64-bit Windows, handles are pointer-sized — "Int"/"UInt" truncates them.
#
# Rules:
#   1. handle-return: Known handle-returning functions must use "Ptr" return type
#   2. handle-param: Variables matching h[A-Z]* should use "Ptr", not "Int"/"UInt"
#
# Handles multi-line DllCall invocations via paren-depth tracking.
#
# Suppress with: ; lint-ignore: dllcall-types
#
# Usage: powershell -File tests\check_dllcall_types.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = issues found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Known handle-returning Windows API functions ===
# These return HANDLE/HWND/HDC/HBITMAP/HICON/etc. — pointer-sized values.
# Return type MUST be "Ptr", not "Int"/"UInt" (which truncates on 64-bit).

$HANDLE_RETURNING = @{}
@(
    # kernel32 — returns HANDLE
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
    # user32 — returns HWND / HHOOK / HICON / etc.
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
    # gdi32 — returns HDC / HBITMAP / HRGN / HBRUSH / HPEN / HFONT
    'CreateCompatibleDC', 'CreateDCW',
    'CreateDIBSection', 'CreateBitmap', 'CreateCompatibleBitmap',
    'CreateRoundRectRgn', 'CreateRectRgn', 'CreateEllipticRgn',
    'CreateFontW', 'CreateFontIndirectW',
    'CreatePen', 'ExtCreatePen',
    'CreateSolidBrush', 'CreatePatternBrush',
    'SelectObject', 'GetStockObject'
) | ForEach-Object { $HANDLE_RETURNING[$_] = $true }

# DllCall type keywords (lowercase) — for return type detection
$TYPE_SET = @{}
@('int','uint','ptr','uptr','short','ushort','char','uchar','float','double','int64') |
    ForEach-Object { $TYPE_SET[$_] = $true }

# Handle variable names where "Int"/"UInt" is correct
# hResult/hRes = HRESULT (32-bit status code)
# hPhys = height in physical pixels (not a handle)
$HANDLE_VAR_EXCLUDE = @{ 'hResult' = $true; 'hRes' = $true; 'hPhys' = $true }

# === Helpers ===

# Character-level search for the closing ) matching the ( at $openParenIdx
function Find-DllCallEnd {
    param([string]$text, [int]$openParenIdx)
    $depth = 0
    $inStr = $false
    for ($i = $openParenIdx; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($inStr) {
            if ($c -eq '"') { $inStr = $false }
            continue
        }
        if ($c -eq '"') { $inStr = $true; continue }
        if ($c -eq '(') { $depth++ }
        elseif ($c -eq ')') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return -1
}

# Line-level paren depth delta (strips strings and comments first)
function Get-ParenDelta {
    param([string]$line)
    $c = $line -replace '"[^"]*"', '""'
    $c = $c -replace "'[^']*'", "''"
    $c = $c -replace '\s;.*$', ''
    return ($c.Split('(')).Count - ($c.Split(')')).Count
}

# === Resolve source directory ===

if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

# === Scan ===

$files = @(Get-ChildItem -Path $SourceDir -Recurse -Filter '*.ahk')
$issues = @()
$dllCallCount = 0

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $inBlockComment = $false
    $accumulating = $false
    $joinedLine = ''
    $startLineNum = 0
    $rawStartLine = ''
    $parenDepth = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $lineNum = $i + 1

        # Block comments
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
            $parenDepth += (Get-ParenDelta $raw)
            if ($parenDepth -gt 0) { continue }
            $accumulating = $false
            # Fall through to analysis
        } else {
            # Skip comment-only lines
            if ($raw -match '^\s*;') { continue }

            # Look for DllCall(
            if ($raw -match 'DllCall\s*\(') {
                # Check lint suppression on the starting line
                if ($raw -match ';\s*lint-ignore:\s*dllcall-types') { continue }

                $joinedLine = $raw
                $startLineNum = $lineNum
                $rawStartLine = $raw

                # Count parens from DllCall( onward
                $dllMatch = [regex]::Match($raw, 'DllCall\s*\(')
                $relevantPart = $raw.Substring($dllMatch.Index)
                $parenDepth = (Get-ParenDelta $relevantPart)

                if ($parenDepth -gt 0) {
                    $accumulating = $true
                    continue
                }
                # Single-line DllCall — fall through
            } else {
                continue
            }
        }

        # === Analyze the accumulated DllCall ===
        $dllCallCount++

        # Locate DllCall( in joined text
        $dllMatch = [regex]::Match($joinedLine, 'DllCall\s*\(')
        if (-not $dllMatch.Success) { continue }
        $parenStart = $dllMatch.Index + $dllMatch.Length - 1  # index of (

        # Find matching )
        $endIdx = Find-DllCallEnd $joinedLine $parenStart
        if ($endIdx -lt 0) { continue }

        # Extract content between ( and )
        $inner = $joinedLine.Substring($parenStart + 1, $endIdx - $parenStart - 1)

        # Extract function name (first quoted string)
        if ($inner -notmatch '^\s*"([^"]+)"') { continue }
        $funcStr = $matches[1]
        $baseName = if ($funcStr -match '\\([^\\]+)$') { $matches[1] } else { $funcStr }

        # --- Detect return type ---
        # Walk backward through $inner to find the last quoted string.
        # If it's a recognized DllCall type keyword, it's the return type.
        # Otherwise, no explicit return type (AHK defaults to "Int").
        $returnType = $null
        $explicitReturn = $false
        $lastQuoted = $null
        $scanPos = $inner.Length - 1
        while ($scanPos -ge 0) {
            if ($inner[$scanPos] -eq '"') {
                $closePos = $scanPos
                $scanPos--
                while ($scanPos -ge 0 -and $inner[$scanPos] -ne '"') { $scanPos-- }
                if ($scanPos -ge 0) {
                    $lastQuoted = $inner.Substring($scanPos + 1, $closePos - $scanPos - 1)
                }
                break
            }
            $scanPos--
        }

        if ($lastQuoted) {
            $lq = $lastQuoted.ToLower().Trim()
            # Handle "Cdecl TypeName" combined format
            if ($lq -match '^cdecl\s+(.+)$') {
                $tp = $matches[1].Trim()
                if ($TYPE_SET.ContainsKey($tp)) {
                    $returnType = $tp
                    $explicitReturn = $true
                }
            } elseif ($TYPE_SET.ContainsKey($lq)) {
                $returnType = $lq
                $explicitReturn = $true
            }
        }
        if (-not $returnType) { $returnType = 'int' }

        # Relative path for reporting
        $relPath = $file.FullName
        if ($relPath.StartsWith($SourceDir)) {
            $relPath = $relPath.Substring($SourceDir.Length).TrimStart('\', '/')
        }

        # --- Rule 1: Handle-returning functions must use "Ptr" ---
        if ($HANDLE_RETURNING.ContainsKey($baseName)) {
            if ($returnType -eq 'int' -or $returnType -eq 'uint') {
                if ($explicitReturn) {
                    $detail = "${baseName}() returns a handle - use `"Ptr`" not `"$lastQuoted`""
                } else {
                    $detail = "${baseName}() returns a handle - return type defaults to `"Int`", use `"Ptr`""
                }
                $issues += [PSCustomObject]@{
                    File   = $relPath
                    Line   = $startLineNum
                    Rule   = 'handle-return'
                    Detail = $detail
                }
            }
        }

        # --- Rule 2: Handle-like variable passed with "Int"/"UInt" ---
        # Match: "Int" or "UInt" type followed by variable starting with h + uppercase
        # Case-insensitive type names, case-SENSITIVE h[A-Z] (handle naming convention)
        $hvMatches = [regex]::Matches($inner, '"([Ii]nt|[Uu][Ii]nt)"\s*,\s*(h[A-Z]\w*)')
        foreach ($m in $hvMatches) {
            $wrongType = $m.Groups[1].Value
            $varName = $m.Groups[2].Value
            if ($HANDLE_VAR_EXCLUDE.ContainsKey($varName)) { continue }
            $issues += [PSCustomObject]@{
                File   = $relPath
                Line   = $startLineNum
                Rule   = 'handle-param'
                Detail = "$varName looks like a handle - use `"Ptr`" not `"$wrongType`""
            }
        }
    }
}

$totalSw.Stop()

# === Report ===

$timingLine = "  Timing: total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $($files.Count) files, $dllCallCount DllCalls analyzed, $($issues.Count) issue(s)"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) DllCall type issue(s) found." -ForegroundColor Red
    Write-Host "  On 64-bit, handles are pointer-sized. Use `"Ptr`" not `"Int`"/`"UInt`"." -ForegroundColor Red
    Write-Host "  Suppress with: ; lint-ignore: dllcall-types" -ForegroundColor Red

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host "`n    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line) [$($issue.Rule)]: $($issue.Detail)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: All DllCall handle types are correct" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
