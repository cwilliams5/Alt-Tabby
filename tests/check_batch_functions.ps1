# check_batch_functions.ps1 - Batched function/global analysis checks
# Combines four enforcement-only standalone checks into one PowerShell process to reduce
# startup overhead and share file I/O + function definition parsing.
# Sub-checks: check_arity, check_dead_functions, check_undefined_calls, check_globals
# Shared file cache: all src/ and test/ .ahk files read once.
#
# Usage: powershell -File tests\check_batch_functions.ps1 [-SourceDir "path\to\src"]
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
$testsDir = Join-Path $projectRoot "tests"

# === Shared file cache (single read for all sub-checks) ===
$srcFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })
$testFiles = @()
if (Test-Path $testsDir) {
    $testFiles = @(Get-ChildItem -Path $testsDir -Filter "*.ahk" -Recurse)
}
# All project AHK files (including lib/ and legacy exclusions per check_undefined_calls)
$allProjectFiles = @(Get-ChildItem -Path $projectRoot -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\legacy\*" })

$fileCache = @{}       # fullPath -> string[] (lines)
$fileCacheText = @{}   # fullPath -> string (joined text)

foreach ($f in $allProjectFiles) {
    if ($fileCache.ContainsKey($f.FullName)) { continue }
    $text = [System.IO.File]::ReadAllText($f.FullName)
    $fileCacheText[$f.FullName] = $text
    $fileCache[$f.FullName] = $text -split "`r?`n"
}

# === Sub-check tracking ===
$subTimings = [System.Collections.ArrayList]::new()
$anyFailed = $false
$failOutput = [System.Text.StringBuilder]::new()

# === Shared helpers ===

function BF_CleanLine {
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

function BF_CountBraces {
    param([string]$line)
    $opens = 0; $closes = 0
    foreach ($c in $line.ToCharArray()) {
        if ($c -eq '{') { $opens++ }
        elseif ($c -eq '}') { $closes++ }
    }
    return @($opens, $closes)
}

$BF_AHK_KEYWORDS = @{}
@('if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
  'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
  'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
  'new', 'super', 'this', 'true', 'false', 'unset', 'isset') |
    ForEach-Object { $BF_AHK_KEYWORDS[$_] = $true }

# AHK v2 built-in functions to skip
$BF_AHK_BUILTINS = @{}
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
    'ObjAddRef', 'ObjFromPtr', 'ObjFromPtrAddRef', 'ObjGetBase',
    'ObjGetCapacity', 'ObjHasOwnProp', 'ObjOwnProps', 'ObjPtr',
    'ObjPtrAddRef', 'ObjRelease', 'ObjSetBase', 'ObjSetCapacity',
    # File
    'FileRead', 'FileAppend', 'FileDelete', 'FileCopy', 'FileMove',
    'FileExist', 'DirExist', 'DirCreate', 'DirDelete', 'DirCopy', 'DirMove',
    'FileOpen', 'FileGetAttrib', 'FileSetAttrib', 'FileGetSize',
    'FileGetTime', 'FileSetTime', 'FileGetVersion', 'FileInstall',
    'FileSelect', 'DirSelect', 'SplitPath', 'IniRead', 'IniWrite', 'IniDelete',
    'FileRecycle', 'FileRecycleEmpty', 'FileEncoding',
    'FileCreateShortcut', 'FileGetShortcut',
    # GUI
    'Gui', 'GuiCtrlFromHwnd', 'GuiFromHwnd', 'MsgBox', 'InputBox', 'ToolTip', 'TrayTip',
    'TraySetIcon', 'Menu', 'MenuBar', 'MenuFromHandle', 'InputHook', 'LoadPicture',
    'IL_Add', 'IL_Create', 'IL_Destroy',
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
    'DetectHiddenText', 'DetectHiddenWindows', 'SetTitleMatchMode', 'SetWinDelay',
    'StatusBarGetText', 'StatusBarWait',
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
    'ListViewGetContent', 'ControlHide', 'ControlShow', 'ControlMove',
    'ControlGetIndex', 'MenuSelect', 'SetControlDelay',
    # Hotkey/input
    'Hotkey', 'Hotstring', 'Suspend', 'BlockInput',
    'GetKeyState', 'GetKeyName', 'GetKeySC', 'GetKeyVK',
    'KeyWait', 'CaretGetPos',
    'Send', 'SendText', 'SendInput', 'SendPlay', 'SendEvent',
    'SendMode', 'SetKeyDelay', 'SetMouseDelay',
    'Click', 'MouseMove', 'MouseClick', 'MouseClickDrag', 'MouseGetPos',
    'HotIf', 'HotIfWinActive', 'HotIfWinExist',
    'HotIfWinNotActive', 'HotIfWinNotExist',
    'InstallKeybdHook', 'InstallMouseHook', 'KeyHistory',
    'SendLevel', 'SetCapsLockState', 'SetDefaultMouseSpeed',
    'SetNumLockState', 'SetScrollLockState', 'SetStoreCapsLockMode',
    # Process/System
    'Run', 'RunAs', 'RunWait', 'ProcessExist', 'ProcessClose', 'ProcessWait',
    'ProcessWaitClose', 'ProcessSetPriority', 'ProcessGetName', 'ProcessGetPath',
    'EnvGet', 'EnvSet', 'ClipWait', 'Shutdown',
    'SysGet', 'SysGetIPAddresses', 'MonitorGet', 'MonitorGetCount', 'MonitorGetName',
    'MonitorGetPrimary', 'MonitorGetWorkArea',
    'SoundGetVolume', 'SoundSetVolume', 'SoundGetMute', 'SoundSetMute',
    'SoundPlay', 'SoundBeep', 'SoundGetInterface', 'SoundGetName',
    'Download', 'ComObject', 'ComObjGet', 'ComObjConnect', 'ComObjQuery',
    'ComObjType', 'ComObjValue', 'ComObjFlags', 'ComObjActive', 'ComCall', 'ComValue',
    'DriveGetCapacity', 'DriveGetFileSystem', 'DriveGetLabel', 'DriveGetList',
    'DriveGetSerial', 'DriveGetSpaceFree', 'DriveGetStatus', 'DriveGetStatusCD',
    'DriveGetType', 'DriveSetLabel', 'DriveLock', 'DriveUnlock', 'DriveEject', 'DriveRetract',
    # Misc
    'DllCall', 'VarSetStrCapacity', 'NumPut', 'NumGet', 'StrPut', 'StrGet',
    'Buffer', 'ClipboardAll',
    'IsSet', 'IsSetRef',
    'SetTimer', 'SetWinDelay', 'SetControlDelay',
    'OnMessage', 'OnClipboardChange', 'OnError', 'OnExit', 'CallbackCreate', 'CallbackFree',
    'Critical', 'Thread', 'Persistent',
    'A_Clipboard', 'Throw', 'Error', 'ValueError', 'TypeError', 'OSError',
    'IndexError', 'MemberError', 'MethodError', 'PropertyError', 'TargetError',
    'TimeoutError', 'UnsetError', 'UnsetItemError', 'ZeroDivisionError',
    'RegRead', 'RegWrite', 'RegDelete', 'RegDeleteKey', 'SetRegView',
    'OutputDebug', 'ListLines', 'ListVars', 'ListHotkeys',
    'DateAdd', 'DateDiff',
    'CoordMode', 'SetDefaultMouseSpeed',
    'PixelGetColor', 'PixelSearch', 'ImageSearch',
    'FileCreateShortcut', 'FileGetShortcut',
    'PostMessage', 'SendMessage',
    'Edit', 'Pause', 'SetWorkingDir',
    'Func', 'BoundFunc', 'Closure', 'Enumerator', 'File', 'RegExMatchInfo', 'VarRef',
    'GetMethod',
    'IsAlnum', 'IsAlpha', 'IsDigit', 'IsFloat', 'IsInteger', 'IsLabel', 'IsLower',
    'IsNumber', 'IsSpace', 'IsTime', 'IsUpper', 'IsXDigit',
    'StrPtr'
) | ForEach-Object { $BF_AHK_BUILTINS[$_] = $true }

# AHK built-in identifiers that should never be treated as user globals
$BF_AHK_BUILTIN_IDS = @('true', 'false', 'unset', 'this', 'super')
$MIN_GLOBAL_NAME_LENGTH = 2

# ============================================================
# Shared infrastructure: Function definition table + file-scope globals
# Built once, used by check_arity, check_dead_functions, check_undefined_calls, check_globals
# ============================================================

# --- Shared function definition table (arity-aware) ---
# funcName -> @{ Required; Max; Variadic; File; Line; RelPath; ParamStr }
$sharedFuncDefs = @{}

# --- Shared file-scope globals (for check_globals) ---
$sharedFileGlobals = @{}  # globalName -> "relpath:lineNum" (src/ only)
$testsDirNorm = ""
if (Test-Path $testsDir) {
    $testsDirNorm = [System.IO.Path]::GetFullPath($testsDir).ToLower().TrimEnd('\') + '\'
}
$sharedTestPerFileGlobals = @{}  # filepath -> @{ globalName -> "relpath:lineNum" }
$sharedTestGlobalCount = 0

# --- For check_undefined_calls: broader definition set (includes lib/, OrdinalIgnoreCase) ---
$ucDefinedFunctions = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$ucKnownVariables = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# Strip-Nested helper for globals extraction
function BF_StripNested {
    param([string]$s)
    $result = [System.Text.StringBuilder]::new($s.Length)
    $depth = 0
    foreach ($c in $s.ToCharArray()) {
        if ($c -eq '(' -or $c -eq '[') { $depth++ }
        elseif ($c -eq ')' -or $c -eq ']') { if ($depth -gt 0) { $depth-- } }
        elseif ($depth -eq 0) { [void]$result.Append($c) }
    }
    return $result.ToString()
}

function BF_ExtractGlobalNames {
    param([string]$decl)
    $names = @()
    $stripped = BF_StripNested $decl
    foreach ($part in $stripped -split ',') {
        $trimmed = $part.Trim()
        if ($trimmed -match '^(\w+)') {
            $name = $Matches[1]
            if ($name.Length -ge $MIN_GLOBAL_NAME_LENGTH -and $name -notin $BF_AHK_BUILTIN_IDS) {
                $names += $name
            }
        }
    }
    return $names
}

# === Shared Pass: Build function definition table + collect file-scope globals ===
$sharedPassSw = [System.Diagnostics.Stopwatch]::StartNew()

# Process ALL project files for function definitions (check_undefined_calls needs lib/)
foreach ($file in $allProjectFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $isSrcFile = $file.FullName -like "$SourceDir\*" -and $file.FullName -notlike "*\lib\*"
    $isTestFile = $testsDirNorm -and $file.FullName.ToLower().StartsWith($testsDirNorm)
    $isLibFile = $file.FullName -like "*\lib\*"

    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $localGlobals = @{}  # per-file collection for test files

    $inBlockComment = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $trimmed = $raw.TrimStart()

        # Block comment tracking
        if ($trimmed.StartsWith('/*')) { $inBlockComment = $true }
        if ($inBlockComment) {
            if ($trimmed.Contains('*/')) { $inBlockComment = $false }
            continue
        }

        $cleaned = BF_CleanLine $raw
        if ($cleaned -eq '') {
            # Still need to check for global/class/lambda patterns on non-empty comment lines
            # for check_undefined_calls. Skip if truly empty.
            if ($trimmed.StartsWith(';') -or $trimmed.StartsWith('#') -or $trimmed.Length -eq 0) {
                # check_undefined_calls: global/lambda/class extraction on raw trimmed
                if (-not $trimmed.StartsWith(';') -and -not $trimmed.StartsWith('#') -and $trimmed.Length -gt 0) {
                    # This path won't trigger since we check above
                }
                continue
            }
            continue
        }

        $braces = BF_CountBraces $cleaned

        # --- check_undefined_calls: global/lambda extraction at ALL depths ---
        if ($cleaned -match '^\s*global\s+(.+)') {
            $declPart = $Matches[1]
            foreach ($chunk in $declPart.Split(',')) {
                $chunk = $chunk.Trim()
                if ($chunk -match '^(\w+)') {
                    [void]$ucKnownVariables.Add($Matches[1])
                }
            }

            # check_globals: collect file-scope globals (only at depth 0, outside functions)
            if ($depth -eq 0 -and -not $inFunc) {
                if ($isSrcFile) {
                    foreach ($gName in (BF_ExtractGlobalNames $declPart)) {
                        if (-not $sharedFileGlobals.ContainsKey($gName)) {
                            $sharedFileGlobals[$gName] = "${relPath}:$($i + 1)"
                        }
                    }
                } elseif ($isTestFile) {
                    foreach ($gName in (BF_ExtractGlobalNames $declPart)) {
                        if (-not $localGlobals.ContainsKey($gName)) {
                            $localGlobals[$gName] = "${relPath}:$($i + 1)"
                        }
                    }
                }
            }
        }

        # check_undefined_calls: Lambda/closure assignments at ALL depths
        if ($cleaned -match '^\s*(\w+)\s*:=\s*\(') {
            [void]$ucKnownVariables.Add($Matches[1])
        }

        # --- Check for function definition at file scope (depth == 0, not inside function) ---
        if ($depth -eq 0 -and -not $inFunc) {

            # check_undefined_calls: Class definitions
            if ($cleaned -match '^\s*class\s+(\w+)') {
                [void]$ucDefinedFunctions.Add($Matches[1])
            }

            # Function definition detection
            if ($cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(([^)]*)\)\s*\{') {
                $funcName = $Matches[1]
                $paramStr = $Matches[2]

                if (-not $BF_AHK_KEYWORDS.ContainsKey($funcName.ToLower())) {
                    # Add to check_undefined_calls definition set (all files)
                    [void]$ucDefinedFunctions.Add($funcName)

                    # Extract params for check_undefined_calls
                    $paramText = $paramStr
                    foreach ($param in $paramText.Split(',')) {
                        $param = $param.Trim()
                        $param = $param -replace '^\*', ''
                        $param = $param -replace '^&', ''
                        if ($param -match '^(\w+)') {
                            [void]$ucKnownVariables.Add($Matches[1])
                        }
                    }

                    # For src/ (non-lib) files: build the full arity-aware definition
                    if ($isSrcFile) {
                        $required = 0
                        $maxParams = 0
                        $isVariadic = $false

                        if ($paramStr.Trim().Length -gt 0) {
                            $params = $paramStr -split ','
                            foreach ($p in $params) {
                                $trimP = $p.Trim()
                                if ($trimP -eq '*' -or $trimP -match '^\w+\*$' -or $trimP -match '\*\s*$') {
                                    $isVariadic = $true
                                    if ($trimP -ne '*') { $maxParams++ }
                                } elseif ($trimP -match ':=') {
                                    $maxParams++
                                } elseif ($trimP -match '^\s*&?\s*\w+\s*$') {
                                    $required++
                                    $maxParams++
                                } elseif ($trimP.Length -gt 0) {
                                    $maxParams++
                                    if ($trimP -notmatch ':=' -and $trimP -notmatch '\*') {
                                        $required++
                                    }
                                }
                            }
                        }

                        if (-not $sharedFuncDefs.ContainsKey($funcName)) {
                            $sharedFuncDefs[$funcName] = @{
                                Required = $required
                                Max      = $maxParams
                                Variadic = $isVariadic
                                File     = $relPath
                                Line     = ($i + 1)
                                ParamStr = $paramStr
                            }
                        }
                    }

                    $inFunc = $true
                    $funcDepth = $depth
                }
            } elseif ($cleaned -match '^\s*(?:static\s+)?(\w+)\s*\((.*)') {
                # check_undefined_calls: broader function definition detection (including => and next-line {)
                $funcName2 = $Matches[1]
                $afterParen = $Matches[2]

                if ($funcName2 -notin @('if', 'while', 'for', 'loop', 'switch', 'catch',
                        'return', 'throw', 'class', 'try', 'else', 'until',
                        'global', 'local', 'static', 'super', 'this')) {
                    # Extract parameters
                    $paramText2 = $afterParen
                    $parenDepth = 1
                    $searchEnd = [Math]::Min($i + 20, $lines.Count - 1)

                    foreach ($ch in $paramText2.ToCharArray()) {
                        if ($ch -eq '(') { $parenDepth++ }
                        elseif ($ch -eq ')') { $parenDepth--; if ($parenDepth -eq 0) { break } }
                    }

                    if ($parenDepth -gt 0) {
                        $sb = [System.Text.StringBuilder]::new($paramText2)
                        for ($j = $i + 1; $j -le $searchEnd; $j++) {
                            $contLine = $lines[$j]
                            [void]$sb.Append(' ').Append($contLine)
                            foreach ($ch in $contLine.ToCharArray()) {
                                if ($ch -eq '(') { $parenDepth++ }
                                elseif ($ch -eq ')') { $parenDepth--; if ($parenDepth -eq 0) { break } }
                            }
                            if ($parenDepth -eq 0) { break }
                        }
                        $paramText2 = $sb.ToString()
                    }

                    $closeIdx = $paramText2.IndexOf(')')
                    if ($closeIdx -ge 0) { $paramText2 = $paramText2.Substring(0, $closeIdx) }

                    foreach ($param in $paramText2.Split(',')) {
                        $param = $param.Trim()
                        $param = $param -replace '^\*', ''
                        $param = $param -replace '^&', ''
                        if ($param -match '^(\w+)') {
                            [void]$ucKnownVariables.Add($Matches[1])
                        }
                    }

                    # Verify it's a definition (has { or => after closing paren)
                    $isDefinition = $false
                    $parenDepth2 = 0
                    $foundCloseParen = $false

                    for ($j = $i; $j -le $searchEnd; $j++) {
                        $checkLine = $lines[$j]
                        foreach ($ch in $checkLine.ToCharArray()) {
                            if ($ch -eq '(') { $parenDepth2++ }
                            elseif ($ch -eq ')') {
                                $parenDepth2--
                                if ($parenDepth2 -eq 0) { $foundCloseParen = $true; break }
                            }
                        }
                        if ($foundCloseParen) {
                            if ($checkLine -match '\)\s*(\{|=>)') {
                                $isDefinition = $true
                            } elseif ($j + 1 -le $searchEnd) {
                                for ($k = $j + 1; $k -le $searchEnd; $k++) {
                                    $nextTrimmed = $lines[$k].Trim()
                                    if ($nextTrimmed -eq '') { continue }
                                    if ($nextTrimmed.StartsWith('{') -or $nextTrimmed.StartsWith('=>')) {
                                        $isDefinition = $true
                                    }
                                    break
                                }
                            }
                            break
                        }
                    }

                    if ($isDefinition) {
                        [void]$ucDefinedFunctions.Add($funcName2)
                    }
                }
            }
        }

        $depth += $braces[0] - $braces[1]
        if ($depth -lt 0) { $depth = 0 }

        if ($inFunc -and $depth -le $funcDepth) {
            $inFunc = $false
            $funcDepth = -1
        }
    }

    if ($isTestFile -and $localGlobals.Count -gt 0) {
        $sharedTestPerFileGlobals[$file.FullName] = $localGlobals
        $sharedTestGlobalCount += $localGlobals.Count
    }
}

$sharedPassSw.Stop()

# ============================================================
# Sub-check 1: check_arity
# Cross-file function arity validation
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Count top-level arguments in a parenthesized argument string.
function BF_CountArgs {
    param([string]$inner)
    $trimmed = $inner.Trim()
    if ($trimmed.Length -eq 0) { return 0 }
    $argCount = 1
    $nestDepth = 0
    $inDoubleStr = $false
    $inSingleStr = $false
    foreach ($c in $inner.ToCharArray()) {
        if ($inDoubleStr) { if ($c -eq '"') { $inDoubleStr = $false }; continue }
        if ($inSingleStr) { if ($c -eq "'") { $inSingleStr = $false }; continue }
        if ($c -eq '"') { $inDoubleStr = $true; continue }
        if ($c -eq "'") { $inSingleStr = $true; continue }
        if ($c -eq '(' -or $c -eq '[' -or $c -eq '{') { $nestDepth++ }
        elseif ($c -eq ')' -or $c -eq ']' -or $c -eq '}') { if ($nestDepth -gt 0) { $nestDepth-- } }
        elseif ($c -eq ',' -and $nestDepth -eq 0) { $argCount++ }
    }
    return $argCount
}

function BF_ExtractParenContent {
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
    return $null
}

function BF_SplitTopLevelArgs {
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

# Pass 1b: Callback variable resolution (from check_arity)
$callbackResolution = @{}
$setCallbacksFuncs = @{}

foreach ($file in $srcFiles) {
    $lines = $fileCache[$file.FullName]
    $depth = 0; $inFunc = $false
    $curFuncName = ''; $curFuncParams = @()
    $curFuncDepth = -1
    $curFuncBody = [System.Collections.ArrayList]::new()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = BF_CleanLine $lines[$i]
        if ($cleaned -eq '') { continue }

        if ($depth -eq 0 -and -not $inFunc -and $cleaned -match '^\s*(\w+)\s*\(([^)]*)\)\s*\{') {
            $fname = $Matches[1]; $pStr = $Matches[2]
            if (-not $BF_AHK_KEYWORDS.ContainsKey($fname.ToLower())) {
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

        $braces = BF_CountBraces $cleaned
        $depth += $braces[0] - $braces[1]
        if ($depth -lt 0) { $depth = 0 }

        if ($inFunc -and $depth -le $curFuncDepth) {
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

# Step 2: Resolve callback wiring
foreach ($file in $srcFiles) {
    $lines = $fileCache[$file.FullName]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        if ($raw.IndexOf('(', [System.StringComparison]::Ordinal) -lt 0) { continue }
        $cleaned = BF_CleanLine $raw
        if ($cleaned -eq '') { continue }

        foreach ($scFunc in $setCallbacksFuncs.Keys) {
            if ($cleaned.IndexOf($scFunc, [System.StringComparison]::Ordinal) -lt 0) { continue }
            $cm = [regex]::Match($cleaned, '(?<![.\w])' + [regex]::Escape($scFunc) + '\s*\(')
            if (-not $cm.Success) { continue }

            $parenPos = $cm.Index + $cm.Length - 1
            $fullText = $cleaned
            $lineIdx = $i
            $afterParen = $fullText.Substring($parenPos)
            $openParens = ($afterParen -split '\(').Count - ($afterParen -split '\)').Count
            while ($openParens -gt 0 -and ($lineIdx + 1) -lt $lines.Count) {
                $lineIdx++
                $nc = BF_CleanLine $lines[$lineIdx]
                if ($nc -eq '') { continue }
                $fullText += ' ' + $nc
                $afterParen = $fullText.Substring($parenPos)
                $openParens = ($afterParen -split '\(').Count - ($afterParen -split '\)').Count
            }

            $reM = [regex]::Match($fullText, '(?<![.\w])' + [regex]::Escape($scFunc) + '\s*\(')
            if (-not $reM.Success) { continue }
            $actualParenPos = $reM.Index + $reM.Length - 1
            $argContent = BF_ExtractParenContent $fullText $actualParenPos
            if ($null -eq $argContent) { continue }

            $argList = BF_SplitTopLevelArgs $argContent
            $mapping = $setCallbacksFuncs[$scFunc]
            foreach ($paramIdx in $mapping.Keys) {
                $globalName = $mapping[$paramIdx]
                if ($paramIdx -lt $argList.Count) {
                    $argVal = $argList[$paramIdx]
                    if ($sharedFuncDefs.ContainsKey($argVal)) {
                        $callbackResolution[$globalName] = $argVal
                    }
                }
            }
        }
    }
}

# Arity check: Find call sites and check argument count
$arityIssues = [System.Collections.ArrayList]::new()

$funcNameSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)
foreach ($fn in $sharedFuncDefs.Keys) { [void]$funcNameSet.Add($fn) }

foreach ($file in $srcFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        if ($raw -match ';\s*lint-ignore:\s*arity') { continue }
        if ($raw.IndexOf('(', [System.StringComparison]::Ordinal) -lt 0) { continue }

        $cleaned = BF_CleanLine $raw
        if ($cleaned -eq '') { continue }

        $callMatches = [regex]::Matches($cleaned, '(?<![.\w%])(\w+)\s*\(')

        foreach ($cm in $callMatches) {
            $callName = $cm.Groups[1].Value
            if ($BF_AHK_KEYWORDS.ContainsKey($callName.ToLower())) { continue }
            if ($BF_AHK_BUILTINS.ContainsKey($callName)) { continue }

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

            if ($cleaned -match ([regex]::Escape($callName) + '\s*\.\s*Bind\s*\(')) { continue }

            $parenPos = $cm.Index + $cm.Length - 1
            $fullText = $cleaned
            $lineIdx = $i
            $openParens = ($fullText.Substring($parenPos) -split '\(').Count - ($fullText.Substring($parenPos) -split '\)').Count
            while ($openParens -gt 0 -and ($lineIdx + 1) -lt $lines.Count) {
                $lineIdx++
                $nextCleaned = BF_CleanLine $lines[$lineIdx]
                if ($nextCleaned -eq '') { continue }
                $fullText += ' ' + $nextCleaned
                $afterParen = $fullText.Substring($parenPos)
                $openParens = ($afterParen -split '\(').Count - ($afterParen -split '\)').Count
            }

            $reMatch = [regex]::Match($fullText, '(?<![.\w%])' + [regex]::Escape($callName) + '\s*\(')
            if (-not $reMatch.Success) { continue }
            $actualParenPos = $reMatch.Index + $reMatch.Length - 1

            $argContent = BF_ExtractParenContent $fullText $actualParenPos
            if ($null -eq $argContent) { continue }

            $argCount = BF_CountArgs $argContent
            $def = $sharedFuncDefs[$resolvedName]

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
                [void]$arityIssues.Add([PSCustomObject]@{
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

if ($arityIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($arityIssues.Count) function arity mismatch(es) found.")
    [void]$failOutput.AppendLine("  AHK v2 crashes at runtime on wrong argument count.")
    [void]$failOutput.AppendLine("  Fix: update the call site to match the function signature.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: arity' on the call line.")

    $grouped = $arityIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Function)() - $($issue.Detail)")
            [void]$failOutput.AppendLine("        (defined at $($issue.DefFile):$($issue.DefLine))")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_arity"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 2: check_dead_functions
# Finds functions defined in src/ that are never referenced
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$DEAD_FUNC_SUPPRESSION = 'lint-ignore: dead-function'

$ENTRY_POINT_PATTERNS = @(
    '_OnExit',
    '_OnError',
    'OnExitWrapper',
    '_Main$',
    '^GetAppVersion$'
)
$entryPointRegex = [regex]::new(($ENTRY_POINT_PATTERNS -join '|'), 'Compiled, IgnoreCase')

# Build function definition list from sharedFuncDefs (src/ only)
$deadFuncDefs = @{}
foreach ($file in $srcFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $inBlockComment2 = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($inBlockComment2) {
            if ($raw -match '\*/') { $inBlockComment2 = $false }
            continue
        }
        if ($raw -match '^\s*/\*') { $inBlockComment2 = $true; continue }
        if ($raw -match '^\s*;') { continue }

        if ($raw -match '^\s*(?:static\s+)?([A-Za-z_]\w*)\s*\(') {
            $funcName = $Matches[1]
            if ($BF_AHK_KEYWORDS.ContainsKey($funcName.ToLower())) { continue }

            $hasBrace = $raw -match '\{'
            if (-not $hasBrace -and ($i + 1) -lt $lines.Count) {
                $nextLine = $lines[$i + 1]
                if ($nextLine -match '^\s*\{') { $hasBrace = $true }
            }
            if (-not $hasBrace) { continue }

            if (-not $deadFuncDefs.ContainsKey($funcName)) {
                $deadFuncDefs[$funcName] = @{
                    File    = $file.FullName
                    Line    = $i + 1
                    RelPath = $relPath
                    Raw     = $raw
                }
            }
        }
    }
}

# Build reference index
$allDeadFuncNames = @($deadFuncDefs.Keys)
$refIndex = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$rxStripComment = [regex]::new('\s;.*$', 'Compiled')

foreach ($filePath in $fileCacheText.Keys) {
    $text = $fileCacheText[$filePath]
    $lines = $fileCache[$filePath]

    $candidates = [System.Collections.ArrayList]::new()
    foreach ($funcName in $allDeadFuncNames) {
        if ($refIndex.Contains($funcName)) { continue }
        if ($text.IndexOf($funcName, [System.StringComparison]::Ordinal) -ge 0) {
            [void]$candidates.Add($funcName)
        }
    }

    if ($candidates.Count -eq 0) { continue }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Length -gt 0 -and $line.TrimStart().StartsWith(';')) { continue }

        $cleaned = $line
        if ($cleaned.IndexOf(';') -ge 0) {
            $cleaned = $rxStripComment.Replace($cleaned, '')
        }

        for ($ci = $candidates.Count - 1; $ci -ge 0; $ci--) {
            $funcName = $candidates[$ci]
            if ($cleaned.IndexOf($funcName, [System.StringComparison]::Ordinal) -ge 0) {
                $def = $deadFuncDefs[$funcName]
                if ($filePath -eq $def.File -and ($i + 1) -eq $def.Line) { continue }
                [void]$refIndex.Add($funcName)
                $candidates.RemoveAt($ci)
            }
        }

        if ($candidates.Count -eq 0) { break }
    }
}

$deadFunctions = [System.Collections.ArrayList]::new()
foreach ($funcName in $allDeadFuncNames) {
    $def = $deadFuncDefs[$funcName]
    if ($def.Raw.Contains($DEAD_FUNC_SUPPRESSION)) { continue }
    if ($entryPointRegex.IsMatch($funcName)) { continue }

    if (-not $refIndex.Contains($funcName)) {
        [void]$deadFunctions.Add([PSCustomObject]@{
            Name = $funcName
            File = $def.RelPath
            Line = $def.Line
        })
    }
}

if ($deadFunctions.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($deadFunctions.Count) dead function(s) found (defined but never referenced).")
    [void]$failOutput.AppendLine("  Dead functions indicate incomplete refactors and bloat the compiled binary.")
    [void]$failOutput.AppendLine("  Fix: remove the function, or suppress with '; lint-ignore: dead-function'.")

    $grouped = $deadFunctions | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Name)()")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_dead_functions"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 3: check_undefined_calls
# Detect calls to functions not defined in the codebase
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ucDefinedFunctions and ucKnownVariables already populated in shared pass

$ucKeywords = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($kw in @('if', 'while', 'for', 'loop', 'switch', 'catch', 'return', 'throw',
      'class', 'static', 'try', 'else', 'finally', 'until', 'not', 'and',
      'or', 'global', 'local', 'new', 'super', 'this', 'isset', 'in')) {
    [void]$ucKeywords.Add($kw)
}

$ucBuiltinSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($b in $BF_AHK_BUILTINS.Keys) { [void]$ucBuiltinSet.Add($b) }

$undefined = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($file in $srcFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$SourceDir\", "")
    $inBlockComment3 = $false

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        $trimmed = $line.TrimStart()

        if ($trimmed.StartsWith('/*')) { $inBlockComment3 = $true }
        if ($inBlockComment3) {
            if ($trimmed.Contains('*/')) { $inBlockComment3 = $false }
            continue
        }

        if ($trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) { continue }

        $cleanLine = [regex]::Replace($line, '"[^"]*"', '""')
        $cleanLine = [regex]::Replace($cleanLine, "'[^']*'", "''")

        $semiIdx = $cleanLine.IndexOf(' ;')
        if ($semiIdx -ge 0) {
            $cleanLine = $cleanLine.Substring(0, $semiIdx)
        }

        $callMatches = [regex]::Matches($cleanLine, '(?<![.\w])(\w+)\s*\(')

        foreach ($m in $callMatches) {
            $funcName = $m.Groups[1].Value
            if ($ucKeywords.Contains($funcName)) { continue }
            if ($ucDefinedFunctions.Contains($funcName)) { continue }
            if ($ucKnownVariables.Contains($funcName)) { continue }
            if ($ucBuiltinSet.Contains($funcName)) { continue }

            $undefined.Add([PSCustomObject]@{
                File     = $relPath
                Line     = $i + 1
                Function = $funcName
                Context  = $trimmed.Substring(0, [Math]::Min($trimmed.Length, 120)).Trim()
            })
        }
    }
}

if ($undefined.Count -gt 0) {
    $anyFailed = $true
    $groups = $undefined | Group-Object Function | Sort-Object Name
    $uniqueCount = $groups.Count

    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $uniqueCount undefined function(s) called in source files:")
    foreach ($group in $groups) {
        [void]$failOutput.AppendLine("    UNDEFINED: $($group.Name) ($($group.Count) call site(s))")
        foreach ($call in $group.Group) {
            [void]$failOutput.AppendLine("      $($call.File):$($call.Line): $($call.Context)")
        }
    }
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  Fix: Replace with the correct function name, or add to the built-in whitelist")
    [void]$failOutput.AppendLine("  in check_batch_functions.ps1 if this is a legitimate AHK v2 built-in.")
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_undefined_calls"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 4: check_globals
# Detects functions that use file-scope globals without declaration
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$allFilesForGlobals = $srcFiles + $testFiles

# Build combined regex for src/ global names (O(1) file pre-filter)
$srcGlobalRegex = $null
if ($sharedFileGlobals.Count -gt 0) {
    $escapedNames = @($sharedFileGlobals.Keys | ForEach-Object { [regex]::Escape($_) })
    $srcGlobalRegex = [regex]::new('(?:' + ($escapedNames -join '|') + ')', 'Compiled')
}

# Pre-compile per-global boundary regex
$globalBoundaryRegex = @{}
foreach ($gName in $sharedFileGlobals.Keys) {
    $e = [regex]::Escape($gName)
    $globalBoundaryRegex[$gName] = [regex]::new("\b$e\b")
}

$globalsIssues = [System.Collections.ArrayList]::new()
$phantomIssues = [System.Collections.ArrayList]::new()
$funcCount = 0

foreach ($file in $allFilesForGlobals) {
    if (-not $fileCache.ContainsKey($file.FullName)) { continue }
    $isTestFile = $testsDirNorm -and $file.FullName.ToLower().StartsWith($testsDirNorm)

    if ($isTestFile) {
        if ($sharedTestPerFileGlobals.ContainsKey($file.FullName)) {
            $checkGlobals = $sharedTestPerFileGlobals[$file.FullName]
        } else {
            continue
        }
    } else {
        $checkGlobals = $sharedFileGlobals
    }

    $lines = $fileCache[$file.FullName]

    # Pre-filter
    if ($fileCacheText.ContainsKey($file.FullName)) {
        $joinedText = $fileCacheText[$file.FullName]
    } else {
        continue
    }
    if (-not $isTestFile) {
        if ($null -eq $srcGlobalRegex -or -not $srcGlobalRegex.IsMatch($joinedText)) { continue }
    } else {
        $hasAnyGlobal = $false
        foreach ($gName in $checkGlobals.Keys) {
            if ($joinedText.IndexOf($gName, [System.StringComparison]::Ordinal) -ge 0) {
                $hasAnyGlobal = $true; break
            }
        }
        if (-not $hasAnyGlobal) { continue }
    }

    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcName = ""
    $funcStartLine = 0
    $funcDeclaredGlobals = @{}
    $funcGlobalDeclLines = @{}
    $funcParams = @{}
    $funcLocals = @{}
    $funcBodyLines = [System.Collections.ArrayList]::new()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = BF_CleanLine $lines[$i]

        if (-not $inFunc -and $cleaned -ne '' -and $cleaned -match '^\s*(?:static\s+)?(\w+)\s*\(([^)]*)\)') {
            $fname = $Matches[1]
            $paramStr = $Matches[2]
            if (-not $BF_AHK_KEYWORDS.ContainsKey($fname.ToLower()) -and $cleaned -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcStartLine = $i + 1
                $funcDepth = $depth
                $funcDeclaredGlobals = @{}
                $funcGlobalDeclLines = @{}
                $funcLocals = @{}
                $funcParams = @{}
                $funcBodyLines = [System.Collections.ArrayList]::new()
                $funcCount++

                foreach ($p in $paramStr -split ',') {
                    if ($p.Trim() -match '^[&*]?(\w+)') {
                        $funcParams[$Matches[1]] = $true
                    }
                }
            }
        }

        $braces = BF_CountBraces $cleaned
        $depth += $braces[0] - $braces[1]

        if ($inFunc) {
            if ($cleaned -ne '') {
                if ($cleaned -match '^\s*global\s+(.+)') {
                    foreach ($gn in (BF_ExtractGlobalNames $Matches[1])) {
                        $funcDeclaredGlobals[$gn] = $true
                        if (-not $funcGlobalDeclLines.ContainsKey($gn)) {
                            $funcGlobalDeclLines[$gn] = @{ Line = ($i + 1); Raw = $lines[$i] }
                        }
                    }
                }
                if ($cleaned -match '^\s*static\s+(\w+)') {
                    $funcLocals[$Matches[1]] = $true
                }
                if ($cleaned -match '^\s*local\s+(.+)') {
                    foreach ($part in $Matches[1] -split ',') {
                        if ($part.Trim() -match '^(\w+)') {
                            $funcLocals[$Matches[1]] = $true
                        }
                    }
                }

                [void]$funcBodyLines.Add(@{ Line = ($i + 1); Text = $cleaned })
            }

            if ($depth -le $funcDepth) {
                $texts = [string[]]::new($funcBodyLines.Count)
                for ($t = 0; $t -lt $funcBodyLines.Count; $t++) {
                    $texts[$t] = $funcBodyLines[$t].Text
                }
                $allText = [string]::Join(" ", $texts)

                $wordMatches = [regex]::Matches($allText, '\b[a-zA-Z_]\w+\b')
                $seenGlobals = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::Ordinal)

                foreach ($wm in $wordMatches) {
                    $gName = $wm.Value
                    if ($gName.Length -lt $MIN_GLOBAL_NAME_LENGTH) { continue }
                    if ($seenGlobals.Contains($gName)) { continue }
                    [void]$seenGlobals.Add($gName)
                    if (-not $checkGlobals.ContainsKey($gName)) { continue }
                    if ($funcDeclaredGlobals.ContainsKey($gName)) { continue }
                    if ($funcParams.ContainsKey($gName)) { continue }
                    if ($funcLocals.ContainsKey($gName)) { continue }

                    $boundaryRx = $globalBoundaryRegex[$gName]
                    $foundLine = $null
                    foreach ($bodyLine in $funcBodyLines) {
                        if ($null -ne $boundaryRx) {
                            $lineMatch = $boundaryRx.IsMatch($bodyLine.Text)
                        } else {
                            $escapedName = [regex]::Escape($gName)
                            $lineMatch = $bodyLine.Text -match "\b$escapedName\b"
                        }
                        if ($lineMatch -and $bodyLine.Text -notmatch '^\s*(?:global|static|local)\s') {
                            $foundLine = $bodyLine
                            break
                        }
                    }

                    if ($foundLine) {
                        [void]$globalsIssues.Add([PSCustomObject]@{
                            File     = $relPath
                            Line     = $foundLine.Line
                            Function = $funcName
                            Global   = $gName
                            Declared = $checkGlobals[$gName]
                        })
                    }
                }

                # Phantom global check (src/ only)
                if (-not $isTestFile) {
                    foreach ($gn in $funcDeclaredGlobals.Keys) {
                        if ($checkGlobals.ContainsKey($gn)) { continue }
                        $declInfo = $funcGlobalDeclLines[$gn]
                        if ($declInfo -and $declInfo.Raw -match 'lint-ignore:\s*phantom-global') { continue }
                        [void]$phantomIssues.Add([PSCustomObject]@{
                            File     = $relPath
                            Line     = $declInfo.Line
                            Function = $funcName
                            Global   = $gn
                        })
                    }
                }

                $inFunc = $false
                $funcDepth = -1
            }
        }
    }
}

if ($globalsIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($globalsIssues.Count) undeclared global reference(s) found.")
    [void]$failOutput.AppendLine("  These will silently become empty strings at runtime (#Warn VarUnset is Off).")
    [void]$failOutput.AppendLine("  Fix: add 'global <name>' declaration inside the function.")

    $grouped = $globalsIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Function)() uses '$($issue.Global)' without 'global' declaration")
            [void]$failOutput.AppendLine("        (declared at $($issue.Declared))")
        }
    }
}

if ($phantomIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($phantomIssues.Count) phantom global declaration(s) found.")
    [void]$failOutput.AppendLine("  These declare globals that don't exist at file scope - likely stale after refactoring.")
    [void]$failOutput.AppendLine("  The variable silently becomes an empty local instead of the intended global.")
    [void]$failOutput.AppendLine("  Fix: update the name to match the current global, or remove the declaration.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: phantom-global' on the declaration line.")

    $grouped = $phantomIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Function)() declares 'global $($issue.Global)' but no such global exists")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_globals"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All function checks passed (check_arity, check_dead_functions, check_undefined_calls, check_globals)" -ForegroundColor Green
}

Write-Host "  Timing: shared=$($sharedPassSw.ElapsedMilliseconds)ms total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
Write-Host "  Stats:  $($sharedFuncDefs.Count) func defs, $($sharedFileGlobals.Count) src globals, $sharedTestGlobalCount test globals, $funcCount functions scanned" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_functions_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
