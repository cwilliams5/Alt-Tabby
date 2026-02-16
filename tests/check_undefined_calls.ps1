# check_undefined_calls.ps1 - Detect calls to functions not defined in the codebase
#
# Catches bugs where a function is called but never defined (e.g., calling
# Jxon_Dump() after replacing the Jxon library with cJSON). AHK v2 only
# reports these at runtime, not at load time.
#
# Approach:
#   1. Collect all function definitions from all project .ahk files
#   2. Compare against function calls in src/ (excluding lib/)
#   3. Flag calls not matching any definition or AHK v2 built-in
#
# Usage: powershell -File tests\check_undefined_calls.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all pass, 1 = undefined calls found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'

# === Resolve directories ===
$projectRoot = (Resolve-Path "$PSScriptRoot\..").Path
if (-not $SourceDir) {
    $SourceDir = Join-Path $projectRoot "src"
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

# === Step 1: Collect function definitions from ALL project .ahk files ===
# Includes lib/ so third-party function definitions are known.
# Excludes legacy/ (dead code).
$allAhkFiles = @(Get-ChildItem -Path $projectRoot -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\legacy\*" })

$definedFunctions = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

foreach ($file in $allAhkFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $lineCount = $lines.Length
    $inBlockComment = $false

    for ($i = 0; $i -lt $lineCount; $i++) {
        $trimmed = $lines[$i].TrimStart()

        # Block comment tracking
        if ($trimmed.StartsWith('/*')) { $inBlockComment = $true }
        if ($inBlockComment) {
            if ($trimmed.Contains('*/')) { $inBlockComment = $false }
            continue
        }

        # Skip line comments and directives
        if ($trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) { continue }

        # Match class definitions: class Name → constructor callable as Name()
        if ($trimmed -match '^class\s+(\w+)') {
            [void]$definedFunctions.Add($Matches[1])
            continue
        }

        # Match function/method definitions: [static] FuncName(
        if ($trimmed -match '^(?:static\s+)?(\w+)\s*\(') {
            $funcName = $Matches[1]

            # Skip keywords that syntactically look like func(
            if ($funcName -in @('if', 'while', 'for', 'loop', 'switch', 'catch',
                               'return', 'throw', 'class', 'try', 'else', 'until',
                               'global', 'local', 'static', 'super', 'this')) {
                continue
            }

            # Verify it's a definition: look for { or => after closing )
            $isDefinition = $false
            $searchEnd = [Math]::Min($i + 20, $lineCount - 1)
            $parenDepth = 0
            $foundCloseParen = $false

            for ($j = $i; $j -le $searchEnd; $j++) {
                $checkLine = $lines[$j]

                foreach ($ch in $checkLine.ToCharArray()) {
                    if ($ch -eq '(') { $parenDepth++ }
                    elseif ($ch -eq ')') {
                        $parenDepth--
                        if ($parenDepth -eq 0) { $foundCloseParen = $true; break }
                    }
                }

                if ($foundCloseParen) {
                    # Check for { or => after closing ) on this line
                    if ($checkLine -match '\)\s*(\{|=>)') {
                        $isDefinition = $true
                    } elseif ($j + 1 -le $searchEnd) {
                        # Check next non-empty line for { or =>
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
                [void]$definedFunctions.Add($funcName)
            }
        }
    }
}

# === Step 1b: Collect global variable names (callable as callback references) ===
# Patterns: "global varName", "global varName := value", "global var1, var2"
# These are variables that may hold function references (callback pattern).
$knownVariables = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

foreach ($file in $allAhkFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $inBlockComment = $false

    foreach ($line in $lines) {
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith('/*')) { $inBlockComment = $true }
        if ($inBlockComment) {
            if ($trimmed.Contains('*/')) { $inBlockComment = $false }
            continue
        }
        if ($trimmed.StartsWith(';')) { continue }

        # Match: global varName [, varName2, ...] [:= value]
        if ($trimmed -match '^global\s+(.+)') {
            $declPart = $Matches[1]
            # Split by comma, extract variable names
            foreach ($chunk in $declPart.Split(',')) {
                $chunk = $chunk.Trim()
                # Extract name before := or end
                if ($chunk -match '^(\w+)') {
                    [void]$knownVariables.Add($Matches[1])
                }
            }
        }

        # Match lambda/closure assignments: varName := (params) => expr
        # or varName := (params) { body }
        # These create callable local variables (e.g., clamp := (v, lo, hi) => ...)
        if ($trimmed -match '^(\w+)\s*:=\s*\(') {
            [void]$knownVariables.Add($Matches[1])
        }
    }
}

# === Step 1c: Collect function parameter names (callable as passed-in callbacks) ===
# When a function is defined as FuncName(callback, cmp, logFn), those parameter
# names may be called like callback() inside the body. Add them to known set.
foreach ($file in $allAhkFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $lineCount = $lines.Length
    $inBlockComment = $false

    for ($i = 0; $i -lt $lineCount; $i++) {
        $trimmed = $lines[$i].TrimStart()
        if ($trimmed.StartsWith('/*')) { $inBlockComment = $true }
        if ($inBlockComment) {
            if ($trimmed.Contains('*/')) { $inBlockComment = $false }
            continue
        }
        if ($trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) { continue }

        # Match function definition start: FuncName( or static FuncName(
        if ($trimmed -match '^(?:static\s+)?(\w+)\s*\((.*)') {
            $funcName = $Matches[1]
            if ($funcName -in @('if', 'while', 'for', 'loop', 'switch', 'catch',
                               'return', 'throw', 'class', 'try', 'global', 'local', 'static')) {
                continue
            }

            # Collect all text between parens (may span multiple lines)
            $paramText = $Matches[2]
            $parenDepth = 1  # Already past the opening (
            $searchEnd = [Math]::Min($i + 20, $lineCount - 1)

            # Check if closing ) is on this line
            foreach ($ch in $paramText.ToCharArray()) {
                if ($ch -eq '(') { $parenDepth++ }
                elseif ($ch -eq ')') { $parenDepth--; if ($parenDepth -eq 0) { break } }
            }

            if ($parenDepth -gt 0) {
                # Collect continuation lines
                for ($j = $i + 1; $j -le $searchEnd; $j++) {
                    $contLine = $lines[$j]
                    $paramText += ' ' + $contLine
                    foreach ($ch in $contLine.ToCharArray()) {
                        if ($ch -eq '(') { $parenDepth++ }
                        elseif ($ch -eq ')') { $parenDepth--; if ($parenDepth -eq 0) { break } }
                    }
                    if ($parenDepth -eq 0) { break }
                }
            }

            # Extract parameter names from collected text (before closing paren)
            $closeIdx = $paramText.IndexOf(')')
            if ($closeIdx -ge 0) { $paramText = $paramText.Substring(0, $closeIdx) }

            # Split by comma and extract names (ignore defaults, types, ByRef/&)
            foreach ($param in $paramText.Split(',')) {
                $param = $param.Trim()
                $param = $param -replace '^\*', ''    # variadic *
                $param = $param -replace '^&', ''     # ByRef &
                if ($param -match '^(\w+)') {
                    [void]$knownVariables.Add($Matches[1])
                }
            }
        }
    }
}

# === Step 2: AHK v2 built-in functions whitelist ===
# Comprehensive list of AHK v2 built-in functions and constructors.
# Method calls (obj.Method) are already filtered by the call scanner.
$ahkBuiltins = @(
    # Math
    'Abs', 'Ceil', 'Exp', 'Floor', 'Log', 'Ln', 'Max', 'Min', 'Mod', 'Round', 'Sqrt',
    'Sin', 'Cos', 'Tan', 'ASin', 'ACos', 'ATan', 'Random', 'Integer', 'Float', 'Number',
    # String
    'Chr', 'Format', 'FormatTime', 'InStr', 'LTrim', 'Ord', 'RegExMatch', 'RegExReplace',
    'RTrim', 'Sort', 'StrCompare', 'StrGet', 'StrLen', 'StrLower', 'StrPtr', 'StrPut',
    'StrReplace', 'StrSplit', 'StrUpper', 'SubStr', 'Trim', 'String',
    # Type checking
    'HasBase', 'HasMethod', 'HasProp', 'IsAlnum', 'IsAlpha', 'IsDigit', 'IsFloat',
    'IsInteger', 'IsLabel', 'IsLower', 'IsNumber', 'IsObject', 'IsSet', 'IsSetRef',
    'IsSpace', 'IsTime', 'IsUpper', 'IsXDigit', 'Type', 'GetMethod',
    # Object / Collection constructors
    'Array', 'Map', 'Object', 'Buffer',
    'ObjAddRef', 'ObjBindMethod', 'ObjFromPtr', 'ObjFromPtrAddRef', 'ObjGetBase',
    'ObjGetCapacity', 'ObjHasOwnProp', 'ObjOwnPropCount', 'ObjOwnProps', 'ObjPtr',
    'ObjPtrAddRef', 'ObjRelease', 'ObjSetBase', 'ObjSetCapacity',
    # Memory
    'NumGet', 'NumPut', 'VarSetStrCapacity',
    # GUI
    'Gui', 'GuiCtrlFromHwnd', 'GuiFromHwnd', 'LoadPicture', 'MenuFromHandle',
    'IL_Add', 'IL_Create', 'IL_Destroy', 'MenuBar', 'Menu',
    # Dialog
    'InputBox', 'MsgBox', 'ToolTip', 'TrayTip', 'TraySetIcon', 'FileSelect', 'DirSelect',
    # File I/O
    'DirCopy', 'DirCreate', 'DirDelete', 'DirExist', 'DirMove', 'Download',
    'FileAppend', 'FileCopy', 'FileCreateShortcut', 'FileDelete', 'FileEncoding',
    'FileExist', 'FileGetAttrib', 'FileGetShortcut', 'FileGetSize', 'FileGetTime',
    'FileGetVersion', 'FileInstall', 'FileMove', 'FileOpen', 'FileRead',
    'FileRecycle', 'FileRecycleEmpty', 'FileSetAttrib', 'FileSetTime', 'SplitPath',
    # Registry
    'RegDelete', 'RegDeleteKey', 'RegRead', 'RegWrite', 'SetRegView',
    # INI
    'IniDelete', 'IniRead', 'IniWrite',
    # Window
    'WinActivate', 'WinActivateBottom', 'WinActive', 'WinClose', 'WinExist',
    'WinGetClass', 'WinGetClientPos', 'WinGetControls', 'WinGetControlsHwnd',
    'WinGetCount', 'WinGetExStyle', 'WinGetID', 'WinGetIDLast', 'WinGetList',
    'WinGetMinMax', 'WinGetPID', 'WinGetPos', 'WinGetProcessName', 'WinGetProcessPath',
    'WinGetStyle', 'WinGetText', 'WinGetTitle', 'WinGetTransColor', 'WinGetTransparent',
    'WinHide', 'WinKill', 'WinMaximize', 'WinMinimize', 'WinMove', 'WinMoveBottom',
    'WinMoveTop', 'WinRedraw', 'WinRestore', 'WinSetAlwaysOnTop', 'WinSetEnabled',
    'WinSetExStyle', 'WinSetRegion', 'WinSetStyle', 'WinSetTitle', 'WinSetTransColor',
    'WinSetTransparent', 'WinShow', 'WinWait', 'WinWaitActive', 'WinWaitClose',
    'WinWaitNotActive', 'DetectHiddenText', 'DetectHiddenWindows', 'SetTitleMatchMode',
    'SetWinDelay', 'StatusBarGetText', 'StatusBarWait',
    # Control
    'ControlClick', 'ControlFocus', 'ControlGetChecked', 'ControlGetChoice',
    'ControlGetClassNN', 'ControlGetEnabled', 'ControlGetFocus', 'ControlGetHwnd',
    'ControlGetIndex', 'ControlGetItems', 'ControlGetPos', 'ControlGetStyle',
    'ControlGetExStyle', 'ControlGetText', 'ControlGetVisible', 'ControlHide',
    'ControlMove', 'ControlSend', 'ControlSendText', 'ControlSetChecked',
    'ControlSetEnabled', 'ControlSetStyle', 'ControlSetExStyle', 'ControlSetText',
    'ControlShow', 'EditGetCurrentCol', 'EditGetCurrentLine', 'EditGetLine',
    'EditGetLineCount', 'EditGetSelectedText', 'EditPaste', 'ListViewGetContent',
    'MenuSelect', 'SetControlDelay',
    # Process
    'ProcessClose', 'ProcessExist', 'ProcessGetName', 'ProcessGetPath',
    'ProcessSetPriority', 'ProcessWait', 'ProcessWaitClose', 'Run', 'RunAs', 'RunWait',
    'Shutdown',
    # Keyboard / Mouse / Input
    'BlockInput', 'Click', 'CoordMode', 'GetKeyName', 'GetKeySC', 'GetKeyState',
    'GetKeyVK', 'Hotkey', 'HotIf', 'HotIfWinActive', 'HotIfWinExist',
    'HotIfWinNotActive', 'HotIfWinNotExist', 'Hotstring', 'InputHook',
    'InstallKeybdHook', 'InstallMouseHook', 'KeyHistory', 'KeyWait',
    'MouseClick', 'MouseClickDrag', 'MouseGetPos', 'MouseMove',
    'Send', 'SendEvent', 'SendInput', 'SendLevel', 'SendMode', 'SendPlay', 'SendText',
    'SetCapsLockState', 'SetDefaultMouseSpeed', 'SetKeyDelay', 'SetMouseDelay',
    'SetNumLockState', 'SetScrollLockState', 'SetStoreCapsLockMode', 'CaretGetPos',
    # COM
    'ComCall', 'ComObjActive', 'ComObjConnect', 'ComObjGet', 'ComObjQuery',
    'ComObjType', 'ComObjValue', 'ComObject', 'ComValue',
    # Callback
    'CallbackCreate', 'CallbackFree',
    # DllCall
    'DllCall',
    # Messages / Events
    'OnClipboardChange', 'OnError', 'OnExit', 'OnMessage', 'PostMessage', 'SendMessage',
    # Timer
    'SetTimer',
    # Thread / Flow
    'Critical', 'Persistent', 'Thread',
    # System
    'EnvGet', 'EnvSet', 'MonitorGet', 'MonitorGetCount', 'MonitorGetName',
    'MonitorGetPrimary', 'MonitorGetWorkArea', 'SysGet', 'SysGetIPAddresses',
    'DriveGetCapacity', 'DriveGetFileSystem', 'DriveGetLabel', 'DriveGetList',
    'DriveGetSerial', 'DriveGetSpaceFree', 'DriveGetStatus', 'DriveGetStatusCD',
    'DriveGetType', 'DriveSetLabel', 'DriveLock', 'DriveUnlock', 'DriveEject', 'DriveRetract',
    # Sound
    'SoundBeep', 'SoundGetInterface', 'SoundGetMute', 'SoundGetName',
    'SoundGetVolume', 'SoundPlay', 'SoundSetMute', 'SoundSetVolume',
    # Date / Time
    'DateAdd', 'DateDiff',
    # Misc
    'ClipboardAll', 'ClipWait', 'Edit', 'ExitApp', 'GroupActivate', 'GroupAdd',
    'GroupClose', 'GroupDeactivate', 'ImageSearch', 'ListHotkeys', 'ListLines',
    'ListVars', 'OutputDebug', 'Pause', 'PixelGetColor', 'PixelSearch',
    'Reload', 'SetWorkingDir', 'Sleep', 'Suspend',
    # Error classes (called as constructors)
    'Error', 'IndexError', 'MemberError', 'MethodError', 'OSError',
    'PropertyError', 'TargetError', 'TimeoutError', 'TypeError',
    'UnsetError', 'UnsetItemError', 'ValueError', 'ZeroDivisionError',
    # Special types
    'Func', 'BoundFunc', 'Closure', 'Enumerator', 'File', 'RegExMatchInfo', 'VarRef'
)

$builtinSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($b in $ahkBuiltins) { [void]$builtinSet.Add($b) }

# === Step 3: Keywords to skip (look like function calls but aren't) ===
$keywords = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($kw in @('if', 'while', 'for', 'loop', 'switch', 'catch', 'return', 'throw',
      'class', 'static', 'try', 'else', 'finally', 'until', 'not', 'and',
      'or', 'global', 'local', 'new', 'super', 'this', 'isset', 'in')) {
    [void]$keywords.Add($kw)
}

# === Step 4: Scan source files for bare function calls ===
# Only scan src/ (excluding lib/ — third-party code).
$sourceFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

$undefined = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($file in $sourceFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$SourceDir\", "")
    $inBlockComment = $false

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        $trimmed = $line.TrimStart()

        # Block comment tracking
        if ($trimmed.StartsWith('/*')) { $inBlockComment = $true }
        if ($inBlockComment) {
            if ($trimmed.Contains('*/')) { $inBlockComment = $false }
            continue
        }

        # Skip line comments and directives
        if ($trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) { continue }

        # Strip string contents to avoid false positives from function names in strings
        $cleanLine = [regex]::Replace($line, '"[^"]*"', '""')
        $cleanLine = [regex]::Replace($cleanLine, "'[^']*'", "''")

        # Strip inline comments (space-semicolon)
        $semiIdx = $cleanLine.IndexOf(' ;')
        if ($semiIdx -ge 0) {
            $cleanLine = $cleanLine.Substring(0, $semiIdx)
        }

        # Find all bare function calls: word( not preceded by . or another word char
        # This excludes method calls like obj.Method( and chained calls
        $callMatches = [regex]::Matches($cleanLine, '(?<![.\w])(\w+)\s*\(')

        foreach ($m in $callMatches) {
            $funcName = $m.Groups[1].Value

            # Skip keywords
            if ($keywords.Contains($funcName)) { continue }

            # Skip if defined anywhere in the project
            if ($definedFunctions.Contains($funcName)) { continue }

            # Skip if known variable (global or function parameter — callback pattern)
            if ($knownVariables.Contains($funcName)) { continue }

            # Skip if AHK v2 built-in
            if ($builtinSet.Contains($funcName)) { continue }

            # Flag it
            $undefined.Add([PSCustomObject]@{
                File     = $relPath
                Line     = $i + 1
                Function = $funcName
                Context  = $trimmed.Substring(0, [Math]::Min($trimmed.Length, 120)).Trim()
            })
        }
    }
}

# === Step 5: Report ===
if ($undefined.Count -gt 0) {
    # Group by function name for cleaner output
    $groups = $undefined | Group-Object Function | Sort-Object Name
    $uniqueCount = $groups.Count

    Write-Host "  FAIL: $uniqueCount undefined function(s) called in source files:" -ForegroundColor Red
    foreach ($group in $groups) {
        Write-Host "    UNDEFINED: $($group.Name) ($($group.Count) call site(s))" -ForegroundColor Red
        foreach ($call in $group.Group) {
            Write-Host "      $($call.File):$($call.Line): $($call.Context)" -ForegroundColor Yellow
        }
    }
    Write-Host ""
    Write-Host "  Fix: Replace with the correct function name, or add to the built-in whitelist" -ForegroundColor Yellow
    Write-Host "  in check_undefined_calls.ps1 if this is a legitimate AHK v2 built-in." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "  Undefined function calls: none found [PASS]" -ForegroundColor Green
    exit 0
}
