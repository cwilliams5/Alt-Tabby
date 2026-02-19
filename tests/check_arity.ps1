# check_arity.ps1 - Cross-file function arity validation
# Detects call sites where argument count doesn't match the function definition:
#   - Too few arguments (missing required params) → runtime crash
#   - Too many arguments (not variadic) → runtime crash
# Neither is caught at parse time by AHK v2.
#
# Also resolves callback variable wiring (SetCallbacks patterns):
#   gIP_PopBatch(N) → resolves to WL_PopIconBatch() → validates arity.
#
# Skips: dynamic calls (%func%()), .Bind() partial application,
#        method calls (obj.Method()), src/lib/ third-party code.
# Suppress: ; lint-ignore: arity
#
# Usage: powershell -File tests\check_arity.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = arity mismatches found

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
$srcFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

Write-Host "  Scanning $($srcFiles.Count) files for function arity mismatches..." -ForegroundColor Cyan

# === Helpers ===
$AHK_KEYWORDS = @{}
@('if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
  'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
  'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
  'new', 'super', 'this', 'true', 'false', 'unset', 'isset') |
    ForEach-Object { $AHK_KEYWORDS[$_] = $true }

# AHK v2 built-in functions to skip (non-exhaustive, covers common ones)
$AHK_BUILTINS = @{}
@(
    # Flow
    'Sleep', 'ExitApp', 'Reload', 'Persistent', 'Exit',
    # String
    'StrLen', 'SubStr', 'InStr', 'StrReplace', 'StrSplit', 'StrLower', 'StrUpper',
    'StrCompare', 'Trim', 'LTrim', 'RTrim', 'RegExMatch', 'RegExReplace',
    'Format', 'FormatTime', 'Sort', 'Chr', 'Ord', 'String',
    # Math
    'Abs', 'Ceil', 'Floor', 'Round', 'Min', 'Max', 'Mod', 'Log', 'Ln', 'Exp', 'Sqrt',
    'Sin', 'Cos', 'Tan', 'ASin', 'ACos', 'ATan', 'Random', 'Integer', 'Float', 'Number',
    # Array/Object
    'Array', 'Map', 'Object', 'ObjBindMethod', 'ObjOwnPropCount',
    'IsObject', 'Type', 'HasBase', 'HasMethod', 'HasProp',
    # File
    'FileRead', 'FileAppend', 'FileDelete', 'FileCopy', 'FileMove',
    'FileExist', 'DirExist', 'DirCreate', 'DirDelete', 'DirCopy',
    'FileOpen', 'FileGetAttrib', 'FileSetAttrib', 'FileGetSize',
    'FileGetTime', 'FileSetTime', 'FileGetVersion', 'FileInstall',
    'FileSelect', 'DirSelect', 'SplitPath', 'IniRead', 'IniWrite', 'IniDelete',
    # GUI
    'Gui', 'MsgBox', 'InputBox', 'ToolTip', 'TrayTip', 'Menu', 'MenuBar',
    'InputHook',
    # Window
    'WinExist', 'WinActive', 'WinGetID', 'WinGetIDLast', 'WinGetCount',
    'WinGetList', 'WinGetTitle', 'WinGetClass', 'WinGetText',
    'WinGetStyle', 'WinGetExStyle', 'WinGetTransparent', 'WinGetTransColor',
    'WinGetMinMax', 'WinGetControls', 'WinGetControlsHwnd',
    'WinGetPID', 'WinGetProcessName', 'WinGetProcessPath',
    'WinGetPos', 'WinGetClientPos',
    'WinActivate', 'WinActivateBottom', 'WinClose', 'WinKill',
    'WinMinimize', 'WinMaximize', 'WinRestore', 'WinHide', 'WinShow',
    'WinMove', 'WinMoveBottom', 'WinMoveTop',
    'WinSetTitle', 'WinSetStyle', 'WinSetExStyle',
    'WinSetTransparent', 'WinSetTransColor', 'WinSetAlwaysOnTop',
    'WinSetEnabled', 'WinSetRegion',
    'WinWait', 'WinWaitActive', 'WinWaitNotActive', 'WinWaitClose',
    'WinRedraw', 'GroupAdd', 'GroupActivate', 'GroupDeactivate', 'GroupClose',
    # Control
    'ControlGetText', 'ControlSetText', 'ControlGetPos',
    'ControlClick', 'ControlSend', 'ControlSendText',
    'ControlGetFocus', 'ControlFocus',
    'ControlGetChecked', 'ControlSetChecked',
    'ControlGetEnabled', 'ControlSetEnabled',
    'ControlGetVisible', 'ControlSetVisible',
    'ControlGetStyle', 'ControlSetStyle',
    'ControlGetExStyle', 'ControlSetExStyle',
    'ControlGetHwnd', 'ControlGetClassNN',
    'ControlGetItems', 'ControlGetChoice', 'ControlChooseIndex', 'ControlChooseString',
    'EditGetCurrentCol', 'EditGetCurrentLine', 'EditGetLine', 'EditGetLineCount',
    'EditGetSelectedText', 'EditPaste',
    'ListViewGetContent',
    # Hotkey/input
    'Hotkey', 'Hotstring', 'Suspend', 'BlockInput',
    'GetKeyState', 'GetKeyName', 'GetKeySC', 'GetKeyVK',
    'KeyWait', 'CaretGetPos',
    'Send', 'SendText', 'SendInput', 'SendPlay', 'SendEvent',
    'SendMode', 'SetKeyDelay', 'SetMouseDelay',
    'Click', 'MouseMove', 'MouseClick', 'MouseClickDrag', 'MouseGetPos',
    # Process/System
    'Run', 'RunWait', 'ProcessExist', 'ProcessClose', 'ProcessWait',
    'ProcessWaitClose', 'ProcessSetPriority',
    'EnvGet', 'EnvSet', 'ClipWait',
    'SysGet', 'MonitorGet', 'MonitorGetCount', 'MonitorGetName',
    'MonitorGetPrimary', 'MonitorGetWorkArea',
    'SoundGetVolume', 'SoundSetVolume', 'SoundGetMute', 'SoundSetMute',
    'SoundPlay', 'SoundBeep',
    'Download', 'ComObject', 'ComObjGet', 'ComObjConnect', 'ComObjQuery',
    'ComObjType', 'ComObjValue', 'ComObjFlags', 'ComObjActive', 'ComCall',
    # Misc
    'DllCall', 'VarSetStrCapacity', 'NumPut', 'NumGet', 'StrPut', 'StrGet',
    'Buffer', 'ClipboardAll',
    'IsSet', 'IsSetRef',
    'SetTimer', 'SetWinDelay', 'SetControlDelay',
    'OnMessage', 'OnError', 'OnExit', 'CallbackCreate', 'CallbackFree',
    'Critical', 'Thread',
    'A_Clipboard', 'Throw', 'Error', 'ValueError', 'TypeError', 'OSError',
    'RegRead', 'RegWrite', 'RegDelete', 'RegDeleteKey',
    'OutputDebug', 'ListLines', 'ListVars', 'ListHotkeys',
    'StatusBarGetText', 'StatusBarWait',
    'DateAdd', 'DateDiff',
    'InstallKeybdHook', 'InstallMouseHook',
    'CoordMode', 'SetDefaultMouseSpeed',
    'PixelGetColor', 'PixelSearch', 'ImageSearch',
    'TraySetIcon', 'FileCreateShortcut', 'FileGetShortcut',
    'PostMessage', 'SendMessage',
    'WinSetExStyle'
) | ForEach-Object { $AHK_BUILTINS[$_] = $true }

function Clean-Line {
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

function Count-Braces {
    param([string]$line)
    $opens = 0; $closes = 0
    foreach ($c in $line.ToCharArray()) {
        if ($c -eq '{') { $opens++ }
        elseif ($c -eq '}') { $closes++ }
    }
    return @($opens, $closes)
}

# Count top-level arguments in a parenthesized argument string.
# Handles nested parens, strings, brackets, braces (object literals), ternary operators.
function Count-Args {
    param([string]$inner)
    $trimmed = $inner.Trim()
    if ($trimmed.Length -eq 0) { return 0 }

    $argCount = 1
    $nestDepth = 0  # combined depth for (), [], {}
    $inDoubleStr = $false
    $inSingleStr = $false

    foreach ($c in $inner.ToCharArray()) {
        if ($inDoubleStr) { if ($c -eq '"') { $inDoubleStr = $false }; continue }
        if ($inSingleStr) { if ($c -eq "'") { $inSingleStr = $false }; continue }
        if ($c -eq '"') { $inDoubleStr = $true; continue }
        if ($c -eq "'") { $inSingleStr = $true; continue }
        if ($c -eq '(' -or $c -eq '[' -or $c -eq '{') { $nestDepth++ }
        elseif ($c -eq ')' -or $c -eq ']' -or $c -eq '}') { if ($nestDepth -gt 0) { $nestDepth-- } }
        elseif ($c -eq ',' -and $nestDepth -eq 0) {
            $argCount++
        }
    }
    return $argCount
}

# Extract matching parenthesized content starting at given position
function Extract-ParenContent {
    param([string]$text, [int]$openPos)
    $depth = 0
    $inDoubleStr = $false
    $inSingleStr = $false
    for ($i = $openPos; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($inDoubleStr) { if ($c -eq '"') { $inDoubleStr = $false }; continue }
        if ($inSingleStr) { if ($c -eq "'") { $inSingleStr = $false }; continue }
        if ($c -eq '"') { $inDoubleStr = $true; continue }
        if ($c -eq "'") { $inSingleStr = $true; continue }
        if ($c -eq '(') { $depth++ }
        elseif ($c -eq ')') {
            $depth--
            if ($depth -eq 0) {
                return $text.Substring($openPos + 1, $i - $openPos - 1)
            }
        }
    }
    return $null  # unbalanced
}

# ============================================================
# Pass 1: Collect function definitions with parameter signatures
# ============================================================
$pass1Sw = [System.Diagnostics.Stopwatch]::StartNew()
$funcDefs = @{}  # funcName -> @{ Required; Max; Variadic; File; Line }
$fileCache = @{}

foreach ($file in $srcFiles) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $lines = $text -split "`r?`n"
    $fileCache[$file.FullName] = $lines

    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $inFunc = $false
    $funcDepth = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        # Only match at file scope (depth == 0) — these are the callable function definitions
        if ($depth -eq 0 -and -not $inFunc -and $cleaned -match '^\s*(\w+)\s*\(([^)]*)\)\s*\{') {
            $funcName = $Matches[1]
            $paramStr = $Matches[2]

            if (-not $AHK_KEYWORDS.ContainsKey($funcName.ToLower())) {
                # Parse parameter signature
                $required = 0
                $maxParams = 0
                $isVariadic = $false

                if ($paramStr.Trim().Length -gt 0) {
                    $params = $paramStr -split ','
                    foreach ($p in $params) {
                        $trimP = $p.Trim()
                        if ($trimP -eq '*' -or $trimP -match '^\w+\*$' -or $trimP -match '\*\s*$') {
                            $isVariadic = $true
                            # A named variadic param (e.g., args*) still counts as a param slot
                            if ($trimP -ne '*') { $maxParams++ }
                        } elseif ($trimP -match ':=') {
                            # Optional parameter with default value
                            $maxParams++
                        } elseif ($trimP -match '^\s*&?\s*\w+\s*$') {
                            # Required parameter (may have & for ByRef)
                            $required++
                            $maxParams++
                        } elseif ($trimP.Length -gt 0) {
                            # Other param patterns
                            $maxParams++
                            if ($trimP -notmatch ':=' -and $trimP -notmatch '\*') {
                                $required++
                            }
                        }
                    }
                }

                # Only record first definition (duplicate_functions check handles conflicts)
                if (-not $funcDefs.ContainsKey($funcName)) {
                    $funcDefs[$funcName] = @{
                        Required = $required
                        Max      = $maxParams
                        Variadic = $isVariadic
                        File     = $relPath
                        Line     = ($i + 1)
                    }
                }

                $inFunc = $true
                $funcDepth = $depth
            }
        }

        $braces = Count-Braces $cleaned
        $depth += $braces[0] - $braces[1]
        if ($depth -lt 0) { $depth = 0 }

        if ($inFunc -and $depth -le $funcDepth) {
            $inFunc = $false
            $funcDepth = -1
        }
    }
}
$pass1Sw.Stop()

# ============================================================
# Pass 1b: Callback variable resolution
# Maps callback globals (e.g., gIP_PopBatch) to their wired
# functions (e.g., WL_PopIconBatch) via SetCallbacks() wiring.
# This enables arity checking when callbacks are invoked through
# global variables: gIP_PopBatch(N) → validates against WL_PopIconBatch.
# ============================================================
$pass1bSw = [System.Diagnostics.Stopwatch]::StartNew()
$callbackResolution = @{}  # globalVarName -> resolved funcName from $funcDefs

# Helper: split argument string at top-level commas (respects nesting)
function Split-TopLevelArgs {
    param([string]$inner)
    $trimmed = $inner.Trim()
    if ($trimmed.Length -eq 0) { return @() }
    $result = [System.Collections.ArrayList]::new()
    $current = [System.Text.StringBuilder]::new()
    $nestDepth = 0; $inDQ = $false; $inSQ = $false
    foreach ($c in $inner.ToCharArray()) {
        if ($inDQ) { if ($c -eq '"') { $inDQ = $false }; [void]$current.Append($c); continue }
        if ($inSQ) { if ($c -eq "'") { $inSQ = $false }; [void]$current.Append($c); continue }
        if ($c -eq '"') { $inDQ = $true; [void]$current.Append($c); continue }
        if ($c -eq "'") { $inSQ = $true; [void]$current.Append($c); continue }
        if ($c -eq '(' -or $c -eq '[' -or $c -eq '{') { $nestDepth++; [void]$current.Append($c) }
        elseif ($c -eq ')' -or $c -eq ']' -or $c -eq '}') {
            if ($nestDepth -gt 0) { $nestDepth-- }
            [void]$current.Append($c)
        }
        elseif ($c -eq ',' -and $nestDepth -eq 0) {
            [void]$result.Add($current.ToString().Trim())
            [void]$current.Clear()
        }
        else { [void]$current.Append($c) }
    }
    if ($current.Length -gt 0) { [void]$result.Add($current.ToString().Trim()) }
    return @($result)
}

# Step 1: Find SetCallbacks-style function definitions.
# Pattern: function body assigns parameters to declared globals.
$setCallbacksFuncs = @{}  # funcName -> @{ ParamIdx -> GlobalName }

foreach ($file in $srcFiles) {
    $lines = $fileCache[$file.FullName]
    $depth = 0; $inFunc = $false
    $curFuncName = ''; $curFuncParams = @()
    $curFuncDepth = -1
    $curFuncBody = [System.Collections.ArrayList]::new()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = Clean-Line $lines[$i]
        if ($cleaned -eq '') { continue }

        if ($depth -eq 0 -and -not $inFunc -and $cleaned -match '^\s*(\w+)\s*\(([^)]*)\)\s*\{') {
            $fname = $Matches[1]; $pStr = $Matches[2]
            if (-not $AHK_KEYWORDS.ContainsKey($fname.ToLower())) {
                $inFunc = $true; $curFuncDepth = $depth
                $curFuncName = $fname
                $curFuncBody.Clear()
                $curFuncParams = @()
                if ($pStr.Trim().Length -gt 0) {
                    foreach ($p in ($pStr -split ',')) {
                        $tp = $p.Trim() -replace '^\s*&?\s*', '' -replace '\s*:=.*$', '' -replace '\*$', ''
                        if ($tp -match '^\w+$') { $curFuncParams += $tp }
                    }
                }
            }
        }

        if ($inFunc) { [void]$curFuncBody.Add($cleaned) }

        $braces = Count-Braces $cleaned
        $depth += $braces[0] - $braces[1]
        if ($depth -lt 0) { $depth = 0 }

        if ($inFunc -and $depth -le $curFuncDepth) {
            # Function ended — check if it wires params to globals
            $bodyGlobals = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($bl in $curFuncBody) {
                if ($bl -match '^\s*global\b\s+(.+)') {
                    foreach ($gv in ($Matches[1] -split ',')) {
                        $gvt = $gv.Trim()
                        if ($gvt -match '^\w+$') { [void]$bodyGlobals.Add($gvt) }
                    }
                }
            }

            $paramIdxToGlobal = @{}
            foreach ($bl in $curFuncBody) {
                if ($bl -match '^\s*(\w+)\s*:=\s*(\w+)\s*$') {
                    $lhs = $Matches[1]; $rhs = $Matches[2]
                    if ($bodyGlobals.Contains($lhs)) {
                        $pIdx = [array]::IndexOf($curFuncParams, $rhs)
                        if ($pIdx -ge 0) { $paramIdxToGlobal[$pIdx] = $lhs }
                    }
                }
            }

            if ($paramIdxToGlobal.Count -ge 2) {
                $setCallbacksFuncs[$curFuncName] = $paramIdxToGlobal
            }

            $inFunc = $false; $curFuncDepth = -1
        }
    }
}

# Step 2: Find call sites of SetCallbacks functions, resolve args to function names
foreach ($file in $srcFiles) {
    $lines = $fileCache[$file.FullName]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        if ($raw.IndexOf('(', [System.StringComparison]::Ordinal) -lt 0) { continue }
        $cleaned = Clean-Line $raw
        if ($cleaned -eq '') { continue }

        foreach ($scFunc in $setCallbacksFuncs.Keys) {
            if ($cleaned.IndexOf($scFunc, [System.StringComparison]::Ordinal) -lt 0) { continue }

            $cm = [regex]::Match($cleaned, '(?<![.\w])' + [regex]::Escape($scFunc) + '\s*\(')
            if (-not $cm.Success) { continue }

            $parenPos = $cm.Index + $cm.Length - 1
            # Handle multi-line calls
            $fullText = $cleaned
            $lineIdx = $i
            $afterParen = $fullText.Substring($parenPos)
            $openParens = ($afterParen -split '\(').Count - ($afterParen -split '\)').Count
            while ($openParens -gt 0 -and ($lineIdx + 1) -lt $lines.Count) {
                $lineIdx++
                $nc = Clean-Line $lines[$lineIdx]
                if ($nc -eq '') { continue }
                $fullText += ' ' + $nc
                $afterParen = $fullText.Substring($parenPos)
                $openParens = ($afterParen -split '\(').Count - ($afterParen -split '\)').Count
            }

            $reM = [regex]::Match($fullText, '(?<![.\w])' + [regex]::Escape($scFunc) + '\s*\(')
            if (-not $reM.Success) { continue }
            $actualParenPos = $reM.Index + $reM.Length - 1
            $argContent = Extract-ParenContent $fullText $actualParenPos
            if ($null -eq $argContent) { continue }

            $argList = Split-TopLevelArgs $argContent
            $mapping = $setCallbacksFuncs[$scFunc]
            foreach ($paramIdx in $mapping.Keys) {
                $globalName = $mapping[$paramIdx]
                if ($paramIdx -lt $argList.Count) {
                    $argVal = $argList[$paramIdx]
                    if ($funcDefs.ContainsKey($argVal)) {
                        $callbackResolution[$globalName] = $argVal
                    }
                }
            }
        }
    }
}
$pass1bSw.Stop()

# ============================================================
# Pass 2: Find call sites and check argument count
# ============================================================
$pass2Sw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()

# Build regex pattern for all known function names (for fast pre-filter)
$funcNameSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)
foreach ($fn in $funcDefs.Keys) { [void]$funcNameSet.Add($fn) }

foreach ($file in $srcFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]

        # Quick pre-filters
        if ($raw -match '^\s*;') { continue }
        if ($raw -match ';\s*lint-ignore:\s*arity') { continue }
        if ($raw.IndexOf('(', [System.StringComparison]::Ordinal) -lt 0) { continue }

        $cleaned = Clean-Line $raw
        if ($cleaned -eq '') { continue }

        # Find all function call patterns: FuncName(
        # Skip: obj.Method(, %dynamic%(, class definitions
        $callMatches = [regex]::Matches($cleaned, '(?<![.\w%])(\w+)\s*\(')

        foreach ($cm in $callMatches) {
            $callName = $cm.Groups[1].Value

            # Skip keywords, builtins
            if ($AHK_KEYWORDS.ContainsKey($callName.ToLower())) { continue }
            if ($AHK_BUILTINS.ContainsKey($callName)) { continue }

            # Resolve: direct function OR callback variable → wired function
            $resolvedName = $callName
            $isCallback = $false
            if (-not $funcNameSet.Contains($callName)) {
                if ($callbackResolution.ContainsKey($callName)) {
                    $resolvedName = $callbackResolution[$callName]
                    $isCallback = $true
                } else {
                    continue
                }
            }

            # Skip .Bind() partial application on the same line
            if ($cleaned -match ([regex]::Escape($callName) + '\s*\.\s*Bind\s*\(')) { continue }

            # Extract the arguments
            $parenPos = $cm.Index + $cm.Length - 1  # position of '('

            # Handle multi-line calls: join continuation lines
            $fullText = $cleaned
            $lineIdx = $i
            $openParens = ($fullText.Substring($parenPos) -split '\(').Count - ($fullText.Substring($parenPos) -split '\)').Count
            while ($openParens -gt 0 -and ($lineIdx + 1) -lt $lines.Count) {
                $lineIdx++
                $nextCleaned = Clean-Line $lines[$lineIdx]
                if ($nextCleaned -eq '') { continue }
                $fullText += ' ' + $nextCleaned
                # Recalculate from the paren position
                $afterParen = $fullText.Substring($parenPos)
                $openParens = ($afterParen -split '\(').Count - ($afterParen -split '\)').Count
            }

            # Re-find the call in the joined text (position may have shifted if we used $cleaned)
            $reMatch = [regex]::Match($fullText, '(?<![.\w%])' + [regex]::Escape($callName) + '\s*\(')
            if (-not $reMatch.Success) { continue }
            $actualParenPos = $reMatch.Index + $reMatch.Length - 1

            $argContent = Extract-ParenContent $fullText $actualParenPos
            if ($null -eq $argContent) { continue }  # unbalanced parens

            $argCount = Count-Args $argContent
            $def = $funcDefs[$resolvedName]

            # Check arity
            $tooFew = $argCount -lt $def.Required
            $tooMany = (-not $def.Variadic) -and ($argCount -gt $def.Max)

            if ($tooFew -or $tooMany) {
                if ($tooFew) {
                    $detail = "too few args: got $argCount, need at least $($def.Required)"
                } else {
                    $detail = "too many args: got $argCount, max is $($def.Max)"
                }
                if ($isCallback) {
                    $detail += " (callback: $callName -> $resolvedName)"
                }
                [void]$issues.Add([PSCustomObject]@{
                    File     = $relPath
                    Line     = ($i + 1)
                    Function = if ($isCallback) { "$callName (-> $resolvedName)" } else { $callName }
                    Detail   = $detail
                    DefFile  = $def.File
                    DefLine  = $def.Line
                })
            }
        }
    }
}
$pass2Sw.Stop()
$totalSw.Stop()

# ============================================================
# Report
# ============================================================
$timingLine = "  Timing: pass1=$($pass1Sw.ElapsedMilliseconds)ms  pass1b=$($pass1bSw.ElapsedMilliseconds)ms  pass2=$($pass2Sw.ElapsedMilliseconds)ms  total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $($funcDefs.Count) function definitions, $($callbackResolution.Count) callback resolutions, $($srcFiles.Count) files"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) function arity mismatch(es) found." -ForegroundColor Red
    Write-Host "  AHK v2 crashes at runtime on wrong argument count." -ForegroundColor Red
    Write-Host "  Fix: update the call site to match the function signature." -ForegroundColor Yellow
    Write-Host "  Suppress: add '; lint-ignore: arity' on the call line." -ForegroundColor Yellow

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host "`n    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            Write-Host "      Line $($issue.Line): $($issue.Function)() - $($issue.Detail)" -ForegroundColor Red
            Write-Host "        (defined at $($issue.DefFile):$($issue.DefLine))" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: All function calls match their definitions" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
