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

# === Steps 1+1b+1c: Collect definitions, globals, and parameters in a single pass ===
# Includes lib/ so third-party function definitions are known.
# Excludes legacy/ (dead code).
$allAhkFiles = @(Get-ChildItem -Path $projectRoot -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\legacy\*" })

$definedFunctions = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$knownVariables = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# File cache for reuse in Step 4
$fileLineCache = @{}

# Keywords shared across all three sub-steps
$defKeywords = @('if', 'while', 'for', 'loop', 'switch', 'catch',
                 'return', 'throw', 'class', 'try', 'else', 'until',
                 'global', 'local', 'static', 'super', 'this')

foreach ($file in $allAhkFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $fileLineCache[$file.FullName] = $lines
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

        # --- Step 1b: Global variable declarations ---
        if ($trimmed -match '^global\s+(.+)') {
            $declPart = $Matches[1]
            foreach ($chunk in $declPart.Split(',')) {
                $chunk = $chunk.Trim()
                if ($chunk -match '^(\w+)') {
                    [void]$knownVariables.Add($Matches[1])
                }
            }
        }

        # --- Step 1b: Lambda/closure assignments ---
        if ($trimmed -match '^(\w+)\s*:=\s*\(') {
            [void]$knownVariables.Add($Matches[1])
        }

        # --- Step 1: Class definitions ---
        if ($trimmed -match '^class\s+(\w+)') {
            [void]$definedFunctions.Add($Matches[1])
            continue
        }

        # --- Step 1 + 1c: Function definitions + parameter extraction ---
        if ($trimmed -match '^(?:static\s+)?(\w+)\s*\((.*)') {
            $funcName = $Matches[1]
            $afterParen = $Matches[2]

            if ($funcName -in $defKeywords) { continue }

            # Step 1c: Extract parameters (always, even if not a verified definition)
            $paramText = $afterParen
            $parenDepth = 1
            $searchEnd = [Math]::Min($i + 20, $lineCount - 1)

            foreach ($ch in $paramText.ToCharArray()) {
                if ($ch -eq '(') { $parenDepth++ }
                elseif ($ch -eq ')') { $parenDepth--; if ($parenDepth -eq 0) { break } }
            }

            if ($parenDepth -gt 0) {
                $sb = [System.Text.StringBuilder]::new($paramText)
                for ($j = $i + 1; $j -le $searchEnd; $j++) {
                    $contLine = $lines[$j]
                    [void]$sb.Append(' ').Append($contLine)
                    foreach ($ch in $contLine.ToCharArray()) {
                        if ($ch -eq '(') { $parenDepth++ }
                        elseif ($ch -eq ')') { $parenDepth--; if ($parenDepth -eq 0) { break } }
                    }
                    if ($parenDepth -eq 0) { break }
                }
                $paramText = $sb.ToString()
            }

            $closeIdx = $paramText.IndexOf(')')
            if ($closeIdx -ge 0) { $paramText = $paramText.Substring(0, $closeIdx) }

            foreach ($param in $paramText.Split(',')) {
                $param = $param.Trim()
                $param = $param -replace '^\*', ''
                $param = $param -replace '^&', ''
                if ($param -match '^(\w+)') {
                    [void]$knownVariables.Add($Matches[1])
                }
            }

            # Step 1: Verify it's a definition (has { or => after closing paren)
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
                [void]$definedFunctions.Add($funcName)
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
    $lines = if ($fileLineCache.ContainsKey($file.FullName)) { $fileLineCache[$file.FullName] } else { [System.IO.File]::ReadAllLines($file.FullName) }
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
