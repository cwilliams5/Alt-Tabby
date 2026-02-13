# check_batch_directives.ps1 - Batched directive/keyword checks
# Combines 5 checks into one PowerShell process to reduce startup overhead.
# Sub-checks: requires_directive, singleinstance, state_strings, winexist_cloaked, bare_try
#
# Usage: powershell -File tests\check_batch_directives.ps1 [-SourceDir "path\to\src"]
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
    $fileCache[$f.FullName] = $text -split "`r?`n"
}

# === Sub-check tracking ===
$subTimings = [System.Collections.ArrayList]::new()
$anyFailed = $false
$failOutput = [System.Text.StringBuilder]::new()

# ============================================================
# Sub-check 1: requires_directive
# Ensures every .ahk file declares #Requires AutoHotkey v2.0
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$EXCLUDED_FILES_RD = @('version_info.ahk')
$rdIssues = @()

foreach ($file in $allFiles) {
    if ($EXCLUDED_FILES_RD -contains $file.Name) { continue }

    $lines = $fileCache[$file.FullName]
    $found = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*#Requires\s+AutoHotkey\s+v2') {
            $found = $true
            break
        }
        if ($line -match '^\s*[^;#\s]' -and $line -notmatch '^\s*;') {
            break
        }
    }

    if (-not $found) {
        $relPath = $file.FullName
        if ($relPath.StartsWith($SourceDir)) {
            $relPath = $relPath.Substring($SourceDir.Length).TrimStart('\', '/')
        }
        $rdIssues += $relPath
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_requires_directive"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($rdIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($rdIssues.Count) file(s) missing #Requires AutoHotkey v2.0")
    [void]$failOutput.AppendLine("  Add as the first line: #Requires AutoHotkey v2.0")
    foreach ($f in $rdIssues | Sort-Object) {
        [void]$failOutput.AppendLine("    $f")
    }
}

# ============================================================
# Sub-check 2: singleinstance
# Entry point needs #SingleInstance Off; modules must not have it
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$siIssues = [System.Collections.ArrayList]::new()
$entryPoint = Join-Path $SourceDir "alt_tabby.ahk"
$standaloneEntryPoints = @(
    (Join-Path $SourceDir "editors\config_registry_editor.ahk")
    (Join-Path $SourceDir "store\store_server.ahk")
)

# Rule 1: Entry point must have #SingleInstance Off
if (Test-Path $entryPoint) {
    $entryPointOk = $false
    $lines = $fileCache[$entryPoint]
    foreach ($line in $lines) {
        if ($line -match '^\s*#SingleInstance\s+Off') { $entryPointOk = $true; break }
    }
    if (-not $entryPointOk) {
        $relPath = $entryPoint.Replace("$projectRoot\", '')
        [void]$siIssues.Add([PSCustomObject]@{
            File = $relPath; Line = 0
            Message = "Entry point missing '#SingleInstance Off'"; Rule = "required"
        })
    }
} else {
    [void]$siIssues.Add([PSCustomObject]@{
        File = "src\alt_tabby.ahk"; Line = 0
        Message = "Entry point file not found"; Rule = "required"
    })
}

# Rule 2: Module files must not have any #SingleInstance directive
$moduleFiles = @($allFiles | Where-Object {
    $_.FullName -ne $entryPoint -and
    $_.FullName -notin $standaloneEntryPoints
})
foreach ($file in $moduleFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*;') { continue }
        if ($line -match 'lint-ignore:\s*singleinstance') { continue }
        if ($line -match '^\s*#SingleInstance') {
            [void]$siIssues.Add([PSCustomObject]@{
                File = $relPath; Line = ($i + 1)
                Message = "Module file has directive: $($line.Trim())"; Rule = "forbidden"
            })
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_singleinstance"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($siIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($siIssues.Count) #SingleInstance issue(s) found.")
    [void]$failOutput.AppendLine("  Entry point needs #SingleInstance Off; module files must not have any #SingleInstance directive.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: singleinstance' on the directive line.")
    $grouped = $siIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            if ($issue.Line -gt 0) {
                [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Message)")
            } else {
                [void]$failOutput.AppendLine("      $($issue.Message)")
            }
        }
    }
}

# ============================================================
# Sub-check 3: state_strings
# Validates gGUI_State string literals (IDLE, ALT_PENDING, ACTIVE)
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$VALID_STATES = @('IDLE', 'ALT_PENDING', 'ACTIVE')
$ssIssues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*;') { continue }
        if ($line -notmatch 'gGUI_State') { continue }
        $stripped = $line -replace '\s;.*$', ''
        $statePatterns = @(
            'gGUI_State\s*:=\s*"([^"]*)"',
            'gGUI_State\s*[!=]=?\s*"([^"]*)"',
            '"([^"]*)"\s*[!=]=?\s*gGUI_State'
        )
        foreach ($pattern in $statePatterns) {
            $regex = [regex]$pattern
            $m = $regex.Matches($stripped)
            foreach ($match in $m) {
                $stateStr = $match.Groups[1].Value
                if ($stateStr -cnotin $VALID_STATES) {
                    [void]$ssIssues.Add([PSCustomObject]@{
                        File = $relPath; Line = ($i + 1)
                        State = $stateStr; Context = $stripped.Trim()
                    })
                }
            }
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_state_strings"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($ssIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($ssIssues.Count) invalid gGUI_State string(s) found.")
    [void]$failOutput.AppendLine("  Valid states: $($VALID_STATES -join ', ')")
    $grouped = $ssIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): invalid state `"$($issue.State)`"  ->  $($issue.Context)")
        }
    }
}

# ============================================================
# Sub-check 4: winexist_cloaked
# Flags WinExist("ahk_id ...") in store/shared code
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$weIssues = [System.Collections.ArrayList]::new()
$weFiles = @($allFiles | Where-Object {
    $_.FullName -like "*\store\*" -or $_.FullName -like "*\shared\*"
})
$WE_SUPPRESSION = 'lint-ignore: winexist-cloaked'

foreach ($file in $weFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw.Contains($WE_SUPPRESSION)) { continue }
        if ($raw -match '^\s*;') { continue }
        # Strip end-of-line comments preserving strings
        $cleaned = $raw
        $inStr = $false; $commentStart = -1
        for ($j = 0; $j -lt $cleaned.Length; $j++) {
            if ($cleaned[$j] -eq '"') { $inStr = -not $inStr }
            elseif (-not $inStr -and $cleaned[$j] -eq ';' -and $j -gt 0 -and $cleaned[$j - 1] -match '\s') {
                $commentStart = $j - 1; break
            }
        }
        if ($commentStart -ge 0) { $cleaned = $cleaned.Substring(0, $commentStart) }

        if ($cleaned -match 'WinExist\s*\([^)]*ahk_id') {
            [void]$weIssues.Add([PSCustomObject]@{
                File = $relPath; Line = ($i + 1); Text = $raw.TrimEnd()
            })
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_winexist_cloaked"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($weIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($weIssues.Count) use(s) of WinExist() with hwnd lookup found.")
    [void]$failOutput.AppendLine("  WinExist('ahk_id ' hwnd) returns FALSE for cloaked windows.")
    [void]$failOutput.AppendLine("  Fix: use DllCall('user32\IsWindow', 'ptr', hwnd) instead.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: winexist-cloaked' on the same line.")
    $grouped = $weIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Text)")
        }
    }
}

# ============================================================
# Sub-check 5: bare_try
# Detects try statements without catch that silently swallow errors
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function BD_BT_CleanLine {
    param([string]$line)
    $cleaned = $line -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace "'[^']*'", "''"
    $cleaned = $cleaned -replace '\s;.*$', ''
    if ($cleaned -match '^\s*;') { return '' }
    return $cleaned
}

function BD_BT_StripComments {
    param([string]$line)
    $stripped = $line -replace '\s;.*$', ''
    if ($stripped -match '^\s*;') { return '' }
    return $stripped
}

function BD_BT_TestAutoExempt {
    param([string]$expr)
    $t = $expr.Trim()
    if ($t -match '(?i)DllCall\(\s*"[^"]*\\?(DestroyIcon|CloseHandle|DisconnectNamedPipe|FlushFileBuffers|DeleteObject|ReleaseDC|SelectObject|DeleteDC|DeleteFont)"') { return $true }
    if ($t -match '(?i)DllCall\(\s*"gdiplus\\Gdip(Delete|Dispose|lusShutdown)') { return $true }
    if ($t -match '(?i)DllCall\(\s*"gdi32\\(DeleteObject|SelectObject|DeleteDC)"') { return $true }
    if ($t -match '(?i)DllCall\(\s*"dwmapi\\Dwm(SetWindowAttribute|Flush)"') { return $true }
    if ($t -match '(?i)^FileDelete\(') { return $true }
    if ($t -match '(?i)^FileCopy\(') { return $true }
    if ($t -match '(?i)^FileMove\(') { return $true }
    if ($t -match '(?i)^FileAppend\(') { return $true }
    if ($t -match '(?i)^DirDelete\(') { return $true }
    if ($t -match '(?i)^SetTimer\(.*,\s*0\s*\)') { return $true }
    if ($t -match '(?i)^Gdip_(Delete|Dispose|Shutdown)') { return $true }
    if ($t -match '(?i)^ProcessClose\(') { return $true }
    if ($t -match '(?i)^WinClose\(') { return $true }
    if ($t -match '(?i)^WinKill\(') { return $true }
    if ($t -match '(?i)^WinActivate\(') { return $true }
    if ($t -match '(?i)^WinSet(AlwaysOnTop|Transparent|ExStyle)\b') { return $true }
    if ($t -match '(?i)^Ini(Write|Read|Delete)\(') { return $true }
    if ($t -match '(?i)^Reg(Write|Read|Delete)\(') { return $true }
    if ($t -match '(?i)^Hotkey\(') { return $true }
    if ($t -match '(?i)^On(Error|Exit)\(') { return $true }
    if ($t -match '(?i)^LogAppend\(') { return $true }
    if ($t -match '(?i)^PostMessage\(') { return $true }
    if ($t -match '(?i)^Send\(') { return $true }
    if ($t -match '(?i)\.(Destroy|Hide|Move|Choose)\(') { return $true }
    if ($t -match '(?i)\.(Value|Text|BackColor)\s*:=') { return $true }
    if ($t -match '(?i)^Run(Wait)?\(') { return $true }
    if ($t -match '(?i)^Theme_UntrackGui\(') { return $true }
    if ($t -match '(?i)^Theme_ApplyToWindow\(') { return $true }
    if ($t -match '(?i)^HideSplashScreen\(') { return $true }
    if ($t -match '(?i)^GUI_AntiFlashReveal\(') { return $true }
    if ($t -match '(?i)^(WinGetTitle|WinGetClass|WinGetProcessName|WinGetID)\(') { return $true }
    if ($t -match '(?i):= (WinGetTitle|WinGetClass|WinGetProcessName|WinGetID)\(') { return $true }
    if ($t -match '(?i):= WinGetTitle\(') { return $true }
    if ($t -match '(?i)DllCall\(\s*"(user32|shcore)\\(SetProcess|GetDpi|GetDpiFor|SetWindowLongPtrW|GetWindowLongPtrW)') { return $true }
    if ($t -match '(?i)^(hr\s*:=\s*)?DllCall\(') { return $true }
    if ($t -match '(?i)^WindowStore_(UpdateFields|UpsertWindow|SetCurrentWorkspace|EnqueueIconRefresh|BatchUpdateFields|ValidateExistence|CleanupAllIcons|CleanupExeIconCache|PruneProcNameCache|PruneExeIconCache)\(') { return $true }
    if ($t -match '(?i):= WindowStore_(UpdateFields|GetByHwnd|SetCurrentWorkspace)\(') { return $true }
    if ($t -match '(?i)^Store_(PushToClients|BroadcastWorkspaceFlips|LogError|LogInfo)\(') { return $true }
    if ($t -match '(?i)^IPC_PipeClient_Send\(') { return $true }
    if ($t -match '(?i)^(IconPump|ProcPump|KomorebiSub|KomorebiLite|WinEventHook|MRU_Lite)_(Stop|EnsureRunning|PruneStaleCache|CleanupWindow|CleanupUwpCache|PruneProcNameCache|PruneExeIconCache|PruneFailedPidCache|Poll)\(') { return $true }
    if ($t -match '(?i):= JSON\.Load\(') { return $true }
    if ($t -match '(?i)^(parsed|stateObj|obj)\s*:= JSON\.Load\(') { return $true }
    if ($t -match '(?i)^return Integer\(') { return $true }
    if ($t -match '(?i):= Integer\(') { return $true }
    if ($t -match '(?i):= Float\(') { return $true }
    if ($t -match '(?i)^(\w+\s*:=\s*)?FileRead\(') { return $true }
    if ($t -match '(?i):= FileRead\(') { return $true }
    if ($t -match '(?i):= Trim\(FileRead\(') { return $true }
    if ($t -match '(?i)^Stats_(FlushToDisk|SendToStore)\(') { return $true }
    if ($t -match '(?i)^LogInitSession\(') { return $true }
    if ($t -match '(?i):= \w+\.\w+$') { return $true }
    if ($t -match '(?i):= BL_CompileWildcard\(') { return $true }
    if ($t -match '(?i)WebView\.(ExecuteScript|Navigate|add_WebMessageReceived)\(') { return $true }
    if ($t -match '(?i)Controller\.(Fill|DefaultBackgroundColor)') { return $true }
    if ($t -match '(?i)Controller\s*:= 0') { return $true }
    if ($t -match '(?i):= IPC_PipeClient_Connect\(') { return $true }
    if ($t -match '(?i)^ProcessUtils_RunWaitHidden\(') { return $true }
    if ($t -match '(?i)^Launcher_ShutdownSubprocesses\(') { return $true }
    if ($t -match '(?i)^DeleteAdminTask\(') { return $true }
    if ($t -match '(?i)^CL_WriteIniPreserveFormat\(') { return $true }
    if ($t -match '(?i):= CL_WriteIniPreserveFormat\(') { return $true }
    if ($t -match '(?i)^ThemeMsgBox\(') { return $true }
    if ($t -match '(?i)\.(Show)\(') { return $true }
    if ($t -match '(?i)\.Call\(') { return $true }
    if ($t -match '(?i)^callback\(\)') { return $true }
    if ($t -match '(?i)(FileExist|FileGetSize|FileGetTime|FileGetVersion)\(') { return $true }
    if ($t -match '(?i)^return MsgBox\(') { return $true }
    if ($t -match '(?i)DllCall\(') { return $true }
    if ($t -match '(?i):= \w+\.\w+\b') { return $true }
    if ($t -match '(?i)ComObject\(') { return $true }
    if ($t -match '(?i)\.(ShellExecute|CreateShortcut|Run)\(') { return $true }
    if ($t -match '(?i)\.(RawWrite)\(') { return $true }
    if ($t -match '(?i)^(if|else|return|continue|break|global|local|static|Loop|for|while|switch)\b') { return $true }
    if ($t -match '^\w+\s*:=') { return $true }
    if ($t -match '^\w+\s*\.=') { return $true }
    if ($t -match '^\w+\s*\+=') { return $true }
    if ($t -match '^\w+\+\+') { return $true }
    if ($t -match '^\w+\-\-') { return $true }
    if ($t -match '^\w+\[') { return $true }
    if ($t -match '^\w+\.\w+\(') { return $true }
    if ($t -match '(?i)^try\b') { return $true }
    if ($t -match '(?i)^_?(GUI|Store|Launcher|Viewer|Update|Blacklist|BL|CEN|CEW|CRE|Theme|IPC|WinEnum)') { return $true }
    if ($t -match '(?i)^Sleep\(') { return $true }
    return $false
}

function BD_BT_FindBlockEnd {
    param([string[]]$cleanedLines, [string[]]$rawLines, [int]$openBraceLine, [int]$startDepth)
    $result = @{ EndLine = -1; HasCatch = $false; Statements = [System.Collections.ArrayList]::new() }
    $depth = $startDepth
    for ($ln = $openBraceLine + 1; $ln -lt $cleanedLines.Count; $ln++) {
        $cl = $cleanedLines[$ln]
        if ($cl -eq '') { continue }
        $depthBefore = $depth
        $hitZero = $false
        $afterZeroText = ''
        foreach ($ch in $cl.ToCharArray()) {
            if ($hitZero) {
                $afterZeroText += $ch
                if ($ch -eq '{') { $depth++ }
                elseif ($ch -eq '}') { $depth-- }
                continue
            }
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -le 0) { $hitZero = $true }
            }
        }
        if ($hitZero) {
            $result.EndLine = $ln
            $after = $afterZeroText.Trim()
            if ($after -match '(?i)^(catch|finally)\b') {
                $result.HasCatch = $true
            } else {
                for ($m = $ln + 1; $m -lt $cleanedLines.Count; $m++) {
                    $mcl = $cleanedLines[$m]
                    if ($mcl -eq '') { continue }
                    if ($mcl.Trim() -match '(?i)^(catch|finally)\b') { $result.HasCatch = $true }
                    break
                }
            }
            return $result
        }
        if ($depthBefore -eq 1) {
            $trimmed = $cl.Trim()
            if ($trimmed -ne '{' -and $trimmed -ne '}') {
                $rawStmt = (BD_BT_StripComments $rawLines[$ln]).Trim()
                if ($rawStmt -ne '') { [void]$result.Statements.Add($rawStmt) }
            }
        }
    }
    return $result
}

$BT_AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)

$btIssues = [System.Collections.ArrayList]::new()
$btTryCount = 0
$btExemptCount = 0

foreach ($file in $allFiles) {
    $rawLines = $fileCache[$file.FullName]

    # Pre-filter: skip files without "try"
    $joined = $fileCacheText[$file.FullName]
    if ($joined.IndexOf('try') -lt 0) { continue }

    $relPath = $file.FullName.Replace("$projectRoot\", '')

    # Pre-clean all lines
    $cleanedLines = [string[]]::new($rawLines.Count)
    for ($idx = 0; $idx -lt $rawLines.Count; $idx++) {
        $cleanedLines[$idx] = BD_BT_CleanLine $rawLines[$idx]
    }

    # Pass 1: Identify OnExit handler boundaries
    $onExitRanges = [System.Collections.ArrayList]::new()
    $btDepth = 0; $btInFunc = $false; $btFuncDepth = -1; $btFuncStart = -1; $btFuncName = ""
    for ($idx = 0; $idx -lt $rawLines.Count; $idx++) {
        $cl = $cleanedLines[$idx]
        if ($cl -eq '') { continue }
        if (-not $btInFunc -and $cl -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if ($fname.ToLower() -notin $BT_AHK_KEYWORDS -and $cl -match '\{') {
                $btInFunc = $true; $btFuncName = $fname; $btFuncDepth = $btDepth; $btFuncStart = $idx
            }
        }
        foreach ($ch in $cl.ToCharArray()) {
            if ($ch -eq '{') { $btDepth++ } elseif ($ch -eq '}') { $btDepth-- }
        }
        if ($btInFunc -and $btDepth -le $btFuncDepth) {
            if ($btFuncName -match '(?i)OnExit') {
                [void]$onExitRanges.Add([PSCustomObject]@{ Start = $btFuncStart; End = $idx })
            }
            $btInFunc = $false; $btFuncDepth = -1
        }
    }

    # Pass 2: Find try statements
    for ($i = 0; $i -lt $rawLines.Count; $i++) {
        $cl = $cleanedLines[$i]
        if ($cl -eq '') { continue }
        if ($cl -notmatch '^\s*try\b') { continue }
        $btTryCount++
        $tryLineNum = $i + 1

        # Check if inside OnExit handler
        $inOnExit = $false
        foreach ($r in $onExitRanges) {
            if ($i -ge $r.Start -and $i -le $r.End) { $inOnExit = $true; break }
        }
        if ($inOnExit) { $btExemptCount++; continue }

        $afterTry = ($cl -replace '^\s*try\s*', '').Trim()
        $rawAfterTry = ((BD_BT_StripComments $rawLines[$i]) -replace '^\s*try\s*', '').Trim()

        if ($afterTry -match '^\{') {
            $initDepth = 0
            foreach ($ch in $afterTry.ToCharArray()) {
                if ($ch -eq '{') { $initDepth++ } elseif ($ch -eq '}') { $initDepth-- }
            }
            if ($initDepth -le 0) {
                $hasCatch = $false
                for ($j = $i + 1; $j -lt $rawLines.Count; $j++) {
                    $jcl = $cleanedLines[$j]
                    if ($jcl -eq '') { continue }
                    if ($jcl.Trim() -match '(?i)^(catch|finally)\b') { $hasCatch = $true }
                    break
                }
                if ($hasCatch) { continue }
                $rawBraceContent = ((BD_BT_StripComments $rawLines[$i]) -replace '^\s*try\s*', '').Trim()
                if ($rawBraceContent -match '^\{(.*)\}\s*$') {
                    $inner = $Matches[1].Trim()
                    if ($inner -ne '' -and -not (BD_BT_TestAutoExempt $inner)) {
                        [void]$btIssues.Add([PSCustomObject]@{ File=$relPath; Line=$tryLineNum; Expr=$inner })
                    } else { $btExemptCount++ }
                }
                continue
            }
            $block = BD_BT_FindBlockEnd $cleanedLines $rawLines $i $initDepth
            if ($block.EndLine -lt 0) { continue }
            $i = $block.EndLine
            if ($block.HasCatch) { continue }
            if ($block.Statements.Count -eq 0) { continue }
            $allExempt = $true
            foreach ($stmt in $block.Statements) {
                if (-not (BD_BT_TestAutoExempt $stmt)) { $allExempt = $false; break }
            }
            if ($allExempt) { $btExemptCount++; continue }
            foreach ($stmt in $block.Statements) {
                if (-not (BD_BT_TestAutoExempt $stmt)) {
                    [void]$btIssues.Add([PSCustomObject]@{ File=$relPath; Line=$tryLineNum; Expr=$stmt })
                }
            }
        } elseif ($afterTry -eq '') {
            for ($j = $i + 1; $j -lt $rawLines.Count; $j++) {
                $jcl = $cleanedLines[$j]
                if ($jcl -eq '') { continue }
                $jTrimmed = $jcl.Trim()
                if ($jTrimmed -match '^\{') {
                    $initDepth = 0
                    foreach ($ch in $jcl.ToCharArray()) {
                        if ($ch -eq '{') { $initDepth++ } elseif ($ch -eq '}') { $initDepth-- }
                    }
                    if ($initDepth -le 0) {
                        $hasCatch = $false
                        for ($k = $j + 1; $k -lt $rawLines.Count; $k++) {
                            $kcl = $cleanedLines[$k]
                            if ($kcl -eq '') { continue }
                            if ($kcl.Trim() -match '(?i)^(catch|finally)\b') { $hasCatch = $true }
                            break
                        }
                        $i = $j; break
                    }
                    $block = BD_BT_FindBlockEnd $cleanedLines $rawLines $j $initDepth
                    if ($block.EndLine -lt 0) { $i = $j; break }
                    $i = $block.EndLine
                    if ($block.HasCatch) { break }
                    if ($block.Statements.Count -eq 0) { break }
                    $allExempt = $true
                    foreach ($stmt in $block.Statements) {
                        if (-not (BD_BT_TestAutoExempt $stmt)) { $allExempt = $false; break }
                    }
                    if ($allExempt) { $btExemptCount++; break }
                    foreach ($stmt in $block.Statements) {
                        if (-not (BD_BT_TestAutoExempt $stmt)) {
                            [void]$btIssues.Add([PSCustomObject]@{ File=$relPath; Line=$tryLineNum; Expr=$stmt })
                        }
                    }
                    break
                } else {
                    $rawStmt = (BD_BT_StripComments $rawLines[$j]).Trim()
                    if (BD_BT_TestAutoExempt $rawStmt) { $btExemptCount++ }
                    else {
                        [void]$btIssues.Add([PSCustomObject]@{ File=$relPath; Line=$tryLineNum; Expr=$rawStmt })
                    }
                    $i = $j; break
                }
            }
        } else {
            if (BD_BT_TestAutoExempt $rawAfterTry) { $btExemptCount++ }
            else {
                [void]$btIssues.Add([PSCustomObject]@{ File=$relPath; Line=$tryLineNum; Expr=$rawAfterTry })
            }
        }
    }
}

if ($btIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($btIssues.Count) bare try issue(s) found.")
    [void]$failOutput.AppendLine("  These try statements have no catch block and silently swallow errors.")
    [void]$failOutput.AppendLine("  Fix: add a catch block, or if intentional, add the pattern to auto-exempt list.")
    $grouped = $btIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            $exprShort = $issue.Expr
            if ($exprShort.Length -gt 80) { $exprShort = $exprShort.Substring(0, 77) + "..." }
            [void]$failOutput.AppendLine("      Line $($issue.Line): try without catch: $exprShort")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_bare_try"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All directive checks passed (requires, singleinstance, state_strings, winexist_cloaked, bare_try)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_directives_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
