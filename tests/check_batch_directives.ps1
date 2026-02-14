# check_batch_directives.ps1 - Batched directive/keyword checks
# Combines 6 checks into one PowerShell process to reduce startup overhead.
# Sub-checks: requires_directive, singleinstance, state_strings, winexist_cloaked, bare_try, return_paths, unreachable_code
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

# Pre-compiled exempt patterns for bare_try (avoids per-call regex compilation)
$script:BD_BT_ExemptPatterns = @(
    [regex]::new('(?i)DllCall\(\s*"[^"]*\\?(DestroyIcon|CloseHandle|DisconnectNamedPipe|FlushFileBuffers|DeleteObject|ReleaseDC|SelectObject|DeleteDC|DeleteFont)"')
    [regex]::new('(?i)DllCall\(\s*"gdiplus\\Gdip(Delete|Dispose|lusShutdown)')
    [regex]::new('(?i)DllCall\(\s*"gdi32\\(DeleteObject|SelectObject|DeleteDC)"')
    [regex]::new('(?i)DllCall\(\s*"dwmapi\\Dwm(SetWindowAttribute|Flush)"')
    [regex]::new('(?i)^FileDelete\(')
    [regex]::new('(?i)^FileCopy\(')
    [regex]::new('(?i)^FileMove\(')
    [regex]::new('(?i)^FileAppend\(')
    [regex]::new('(?i)^DirDelete\(')
    [regex]::new('(?i)^SetTimer\(.*,\s*0\s*\)')
    [regex]::new('(?i)^Gdip_(Delete|Dispose|Shutdown)')
    [regex]::new('(?i)^ProcessClose\(')
    [regex]::new('(?i)^WinClose\(')
    [regex]::new('(?i)^WinKill\(')
    [regex]::new('(?i)^WinActivate\(')
    [regex]::new('(?i)^WinSet(AlwaysOnTop|Transparent|ExStyle)\b')
    [regex]::new('(?i)^Ini(Write|Read|Delete)\(')
    [regex]::new('(?i)^Reg(Write|Read|Delete)\(')
    [regex]::new('(?i)^Hotkey\(')
    [regex]::new('(?i)^On(Error|Exit)\(')
    [regex]::new('(?i)^LogAppend\(')
    [regex]::new('(?i)^PostMessage\(')
    [regex]::new('(?i)^Send\(')
    [regex]::new('(?i)\.(Destroy|Hide|Move|Choose)\(')
    [regex]::new('(?i)\.(Value|Text|BackColor)\s*:=')
    [regex]::new('(?i)^Run(Wait)?\(')
    [regex]::new('(?i)^Theme_UntrackGui\(')
    [regex]::new('(?i)^Theme_ApplyToWindow\(')
    [regex]::new('(?i)^HideSplashScreen\(')
    [regex]::new('(?i)^GUI_AntiFlashReveal\(')
    [regex]::new('(?i)^(WinGetTitle|WinGetClass|WinGetProcessName|WinGetID)\(')
    [regex]::new('(?i):= (WinGetTitle|WinGetClass|WinGetProcessName|WinGetID)\(')
    [regex]::new('(?i):= WinGetTitle\(')
    [regex]::new('(?i)DllCall\(\s*"(user32|shcore)\\(SetProcess|GetDpi|GetDpiFor|SetWindowLongPtrW|GetWindowLongPtrW)')
    [regex]::new('(?i)^(hr\s*:=\s*)?DllCall\(')
    [regex]::new('(?i)^WindowStore_(UpdateFields|UpsertWindow|SetCurrentWorkspace|EnqueueIconRefresh|BatchUpdateFields|ValidateExistence|CleanupAllIcons|CleanupExeIconCache|PruneProcNameCache|PruneExeIconCache)\(')
    [regex]::new('(?i):= WindowStore_(UpdateFields|GetByHwnd|SetCurrentWorkspace)\(')
    [regex]::new('(?i)^Store_(PushToClients|BroadcastWorkspaceFlips|LogError|LogInfo)\(')
    [regex]::new('(?i)^IPC_PipeClient_Send\(')
    [regex]::new('(?i)^(IconPump|ProcPump|KomorebiSub|KomorebiLite|WinEventHook|MRU_Lite)_(Stop|EnsureRunning|PruneStaleCache|CleanupWindow|CleanupUwpCache|PruneProcNameCache|PruneExeIconCache|PruneFailedPidCache|Poll)\(')
    [regex]::new('(?i):= JSON\.Load\(')
    [regex]::new('(?i)^(parsed|stateObj|obj)\s*:= JSON\.Load\(')
    [regex]::new('(?i)^return Integer\(')
    [regex]::new('(?i):= Integer\(')
    [regex]::new('(?i):= Float\(')
    [regex]::new('(?i)^(\w+\s*:=\s*)?FileRead\(')
    [regex]::new('(?i):= FileRead\(')
    [regex]::new('(?i):= Trim\(FileRead\(')
    [regex]::new('(?i)^_?Stats_(FlushToDisk|SendToStore)\(')
    [regex]::new('(?i)^LogInitSession\(')
    [regex]::new('(?i):= \w+\.\w+$')
    [regex]::new('(?i):= BL_CompileWildcard\(')
    [regex]::new('(?i)WebView\.(ExecuteScript|Navigate|add_WebMessageReceived)\(')
    [regex]::new('(?i)Controller\.(Fill|DefaultBackgroundColor)')
    [regex]::new('(?i)Controller\s*:= 0')
    [regex]::new('(?i):= IPC_PipeClient_Connect\(')
    [regex]::new('(?i)^ProcessUtils_RunWaitHidden\(')
    [regex]::new('(?i)^Launcher_ShutdownSubprocesses\(')
    [regex]::new('(?i)^DeleteAdminTask\(')
    [regex]::new('(?i)^CL_WriteIniPreserveFormat\(')
    [regex]::new('(?i):= CL_WriteIniPreserveFormat\(')
    [regex]::new('(?i)^ThemeMsgBox\(')
    [regex]::new('(?i)\.(Show)\(')
    [regex]::new('(?i)\.Call\(')
    [regex]::new('(?i)^callback\(\)')
    [regex]::new('(?i)(FileExist|FileGetSize|FileGetTime|FileGetVersion)\(')
    [regex]::new('(?i)^return MsgBox\(')
    [regex]::new('(?i)DllCall\(')
    [regex]::new('(?i):= \w+\.\w+\b')
    [regex]::new('(?i)ComObject\(')
    [regex]::new('(?i)\.(ShellExecute|CreateShortcut|Run)\(')
    [regex]::new('(?i)\.(RawWrite)\(')
    [regex]::new('(?i)^(if|else|return|continue|break|global|local|static|Loop|for|while|switch)\b')
    [regex]::new('^\w+\s*:=')
    [regex]::new('^\w+\s*\.=')
    [regex]::new('^\w+\s*\+=')
    [regex]::new('^\w+\+\+')
    [regex]::new('^\w+\-\-')
    [regex]::new('^\w+\[')
    [regex]::new('^\w+\.\w+\(')
    [regex]::new('(?i)^try\b')
    [regex]::new('(?i)^_?(GUI|Store|Launcher|Viewer|Update|Blacklist|BL|CEN|CEW|CRE|Theme|IPC|WinEnum)')
    [regex]::new('(?i)^Sleep\(')
)

function BD_BT_TestAutoExempt {
    param([string]$expr)
    $t = $expr.Trim()
    foreach ($p in $script:BD_BT_ExemptPatterns) {
        if ($p.IsMatch($t)) { return $true }
    }
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
# Sub-check 6: return_paths
# Detects functions with inconsistent return paths (mixed value/void)
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function BD_RP_CleanLine {
    param([string]$line)
    $trimmed = $line.TrimStart()
    if ($trimmed.Length -eq 0 -or $trimmed[0] -eq ';') { return '' }
    if ($trimmed.IndexOf('"') -lt 0 -and $trimmed.IndexOf("'") -lt 0 -and $trimmed.IndexOf(';') -lt 0) {
        return $trimmed
    }
    $cleaned = $trimmed -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace "'[^']*'", "''"
    $cleaned = $cleaned -replace '\s;.*$', ''
    return $cleaned
}

$RP_SUPPRESSION = 'lint-ignore: mixed-returns'
$rpIssues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    $i = 0
    while ($i -lt $lines.Count) {
        $cleaned = BD_RP_CleanLine $lines[$i]

        # Detect function definition: FuncName(params) {
        if ($cleaned -match '^(\w+)\s*\([^)]*\)\s*\{?\s*$') {
            $funcName = $Matches[1]
            $defLine = $i

            # Skip AHK keywords that look like functions
            if ($funcName -match '^(if|while|for|loop|switch|catch|else|try|class|return)$') {
                $i++; continue
            }

            # Check for suppression on the definition line
            $isSuppressed = $lines[$defLine].Contains($RP_SUPPRESSION)

            # Find opening brace (might be on same line or next line)
            $braceOnSameLine = $cleaned -match '\{\s*$'
            $funcStart = $i
            if (-not $braceOnSameLine) {
                $j = $i + 1
                while ($j -lt $lines.Count) {
                    $nextCleaned = BD_RP_CleanLine $lines[$j]
                    if ($nextCleaned -ne '') {
                        if ($nextCleaned -match '^\{') {
                            $funcStart = $j
                        } else {
                            $funcStart = -1
                        }
                        break
                    }
                    $j++
                }
                if ($funcStart -eq $i) { $i++; continue }
                if ($funcStart -eq -1) { $i++; continue }
            }

            # Extract function body by tracking brace depth
            $depth = 0
            $bodyStart = $funcStart
            $bodyEnd = -1
            $foundOpenBrace = $false

            for ($j = $bodyStart; $j -lt $lines.Count; $j++) {
                $bodyCleaned = BD_RP_CleanLine $lines[$j]
                if ($bodyCleaned -eq '') { continue }

                foreach ($c in $bodyCleaned.ToCharArray()) {
                    if ($c -eq '{') {
                        $depth++
                        $foundOpenBrace = $true
                    }
                    elseif ($c -eq '}') {
                        $depth--
                        if ($foundOpenBrace -and $depth -eq 0) {
                            $bodyEnd = $j
                            break
                        }
                    }
                }
                if ($bodyEnd -ge 0) { break }
            }

            if ($bodyEnd -lt 0) { $i++; continue }

            # Analyze return statements within the function body
            $valueReturns = [System.Collections.ArrayList]::new()
            $voidReturns = [System.Collections.ArrayList]::new()
            $innerDepth = 0

            for ($j = $bodyStart; $j -le $bodyEnd; $j++) {
                $bodyCleaned = BD_RP_CleanLine $lines[$j]
                if ($bodyCleaned -eq '') { continue }

                $prevInnerDepth = $innerDepth
                foreach ($c in $bodyCleaned.ToCharArray()) {
                    if ($c -eq '{') { $innerDepth++ }
                    elseif ($c -eq '}') { $innerDepth-- }
                }

                if ($j -eq $bodyStart) { continue }
                if ($j -eq $bodyEnd) { continue }

                # Skip nested function bodies
                if ($bodyCleaned -match '^\w+\s*\([^)]*\)\s*\{' -and $prevInnerDepth -ge 1) {
                    $skipToDepth = $prevInnerDepth
                    $j++
                    while ($j -le $bodyEnd) {
                        $skipCleaned = BD_RP_CleanLine $lines[$j]
                        if ($skipCleaned -ne '') {
                            foreach ($c in $skipCleaned.ToCharArray()) {
                                if ($c -eq '{') { $innerDepth++ }
                                elseif ($c -eq '}') { $innerDepth-- }
                            }
                            if ($innerDepth -le $skipToDepth) { break }
                        }
                        $j++
                    }
                    continue
                }

                # Check for return statements
                if ($bodyCleaned -match '(?<![.\w])return(?!\w)') {
                    $afterReturn = ''
                    if ($bodyCleaned -match '(?<![.\w])return\s+(.+)') {
                        $afterReturn = $Matches[1].Trim()
                    } elseif ($bodyCleaned -match '(?<![.\w])return\s*$') {
                        $afterReturn = ''
                    } else {
                        continue
                    }

                    $afterReturn = $afterReturn.TrimEnd()
                    if ($afterReturn -match '^(.+?)\s*\}\s*$') {
                        $afterReturn = $Matches[1].Trim()
                    }

                    if ($afterReturn -eq '' -or $afterReturn -eq '}') {
                        [void]$voidReturns.Add($j + 1)
                    } else {
                        [void]$valueReturns.Add($j + 1)
                    }
                }
            }

            if ($valueReturns.Count -gt 0 -and $voidReturns.Count -gt 0 -and -not $isSuppressed) {
                [void]$rpIssues.Add([PSCustomObject]@{
                    File = $relPath
                    Line = ($defLine + 1)
                    Function = $funcName
                    ValueReturns = $valueReturns
                    VoidReturns = $voidReturns
                })
            }

            $i = $bodyEnd + 1
            continue
        }

        $i++
    }
}

$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_return_paths"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($rpIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($rpIssues.Count) function(s) with inconsistent return paths.")
    [void]$failOutput.AppendLine("  AHK v2 bare 'return' silently returns `"`"`. If some paths return a value")
    [void]$failOutput.AppendLine("  and others use bare return, callers may get `"`"` instead of the expected type.")
    [void]$failOutput.AppendLine("  Fix: ensure all return paths return a value, or convert all to bare returns.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: mixed-returns' on the function definition line.")
    foreach ($issue in $rpIssues | Sort-Object File, Line) {
        [void]$failOutput.AppendLine("    $($issue.File):$($issue.Line) $($issue.Function)()")
        $vrLines = ($issue.ValueReturns | ForEach-Object { "L$_" }) -join ', '
        $brLines = ($issue.VoidReturns | ForEach-Object { "L$_" }) -join ', '
        [void]$failOutput.AppendLine("      Value returns: $vrLines")
        [void]$failOutput.AppendLine("      Void returns:  $brLines")
    }
}

# ============================================================
# Sub-check 7: unreachable_code
# Detects code after unconditional return/throw/ExitApp that can
# never execute. Often indicates logic errors or leftover code.
# Only flags code at the same brace depth as the terminator.
# Skips braceless conditionals (if/else/while/for/loop without {).
# Suppress: ; lint-ignore: unreachable-code
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$UC_SUPPRESSION = 'lint-ignore: unreachable-code'

$BT_KEYWORDS_UC = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)

$ucIssues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]

    # Pre-filter: skip files without any terminator keyword
    $joined = $fileCacheText[$file.FullName]
    if ($joined.IndexOf('return') -lt 0 -and
        $joined.IndexOf('throw') -lt 0 -and
        $joined.IndexOf('ExitApp') -lt 0) { continue }

    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $depth = 0
    $inFunc = $false
    $funcDepth = -1

    # State for tracking unconditional terminators
    $afterTerminator = $false
    $terminatorDepth = 0
    $terminatorLine = 0
    $terminatorParenDepth = 0
    $terminatorBracketDepth = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $cleaned = BD_RP_CleanLine $lines[$i]
        if ($cleaned -eq '') { continue }

        # Compute depth changes
        $depthBefore = $depth
        foreach ($c in $cleaned.ToCharArray()) {
            if ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') { $depth-- }
        }

        # Detect function boundaries
        if (-not $inFunc -and $cleaned -match '^(\w+)\s*\([^)]*\)\s*\{') {
            $fnName = $Matches[1]
            if ($fnName.ToLower() -notin $BT_KEYWORDS_UC) {
                $inFunc = $true
                $funcDepth = $depthBefore
                $afterTerminator = $false
            }
        }
        if ($inFunc -and $depth -le $funcDepth -and $depthBefore -gt $funcDepth) {
            $inFunc = $false
            $afterTerminator = $false
            continue
        }

        if (-not $inFunc) { continue }

        # Check for unreachable code after a terminator
        if ($afterTerminator) {
            # If still in multi-line terminator (unclosed parens/brackets), skip as continuation
            if ($terminatorParenDepth -gt 0 -or $terminatorBracketDepth -gt 0) {
                foreach ($c in $cleaned.ToCharArray()) {
                    if ($c -eq '(') { $terminatorParenDepth++ }
                    elseif ($c -eq ')') { $terminatorParenDepth-- }
                    elseif ($c -eq '[') { $terminatorBracketDepth++ }
                    elseif ($c -eq ']') { $terminatorBracketDepth-- }
                }
                # Update terminator line to the end of the multi-line statement
                if ($terminatorParenDepth -le 0 -and $terminatorBracketDepth -le 0) {
                    $terminatorLine = $i + 1
                }
                continue
            }

            if ($depthBefore -lt $terminatorDepth) {
                # Scope closed — stop checking
                $afterTerminator = $false
            } elseif ($depthBefore -eq $terminatorDepth) {
                $trimmed = $cleaned.Trim()

                # Skip braces, labels, compound statement continuations
                if ($trimmed -match '^\}') { $afterTerminator = $false; continue }
                if ($trimmed -eq '{') { continue }
                if ($trimmed -match '^(else|catch|finally)\b') { $afterTerminator = $false; continue }
                if ($trimmed -match '^case\s') { $afterTerminator = $false; continue }
                if ($trimmed -match '^default\s*:') { $afterTerminator = $false; continue }
                if ($trimmed -match '^\w+:\s*$') { $afterTerminator = $false; continue }

                # Skip continuation lines (expression continues from previous line)
                if ($trimmed -match '^[.+\-*/?,:([\[&|~^!<>=]') { continue }
                if ($trimmed -match '^(not|and|or|is|in|contains)\b') { continue }

                # Check suppression
                if ($lines[$i].Contains($UC_SUPPRESSION)) {
                    $afterTerminator = $false
                    continue
                }

                # This line is unreachable
                [void]$ucIssues.Add([PSCustomObject]@{
                    File = $relPath
                    Line = ($i + 1)
                    AfterLine = $terminatorLine
                    Text = $lines[$i].Trim()
                })
                $afterTerminator = $false
            }
        }

        # Detect unconditional terminator
        if (-not $afterTerminator) {
            $trimmed = $cleaned.Trim()
            if ($trimmed -match '^(return\b|throw\b|ExitApp\b)') {
                # Check if preceded by a braceless conditional
                $isBracelessConditional = $false
                for ($j = $i - 1; $j -ge 0; $j--) {
                    $prevCleaned = BD_RP_CleanLine $lines[$j]
                    if ($prevCleaned -eq '') { continue }
                    $prevTrimmed = $prevCleaned.Trim()
                    # Skip continuation lines (multi-line if conditions, etc.)
                    if ($prevTrimmed -match '^[.+\-*/?,:([\[&|~^!<>=]') { continue }
                    if ($prevTrimmed -match '^(not|and|or|is|in|contains)\b') { continue }

                    if ($prevTrimmed -match '(?:^|\})\s*(if\b|else\s+if\b|else\b|while\b|for\b|loop\b|catch\b|try\b)' -and
                        $prevTrimmed -notmatch '\{\s*$') {
                        $isBracelessConditional = $true
                    }
                    break
                }

                if (-not $isBracelessConditional) {
                    # Track paren/bracket balance for multi-line statements
                    $tpd = 0; $tbd = 0
                    foreach ($c in $cleaned.ToCharArray()) {
                        if ($c -eq '(') { $tpd++ }
                        elseif ($c -eq ')') { $tpd-- }
                        elseif ($c -eq '[') { $tbd++ }
                        elseif ($c -eq ']') { $tbd-- }
                    }
                    $afterTerminator = $true
                    $terminatorDepth = $depthBefore
                    $terminatorLine = $i + 1
                    $terminatorParenDepth = $tpd
                    $terminatorBracketDepth = $tbd
                }
            }
        }
    }
}

$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_unreachable_code"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

if ($ucIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($ucIssues.Count) unreachable code line(s) found.")
    [void]$failOutput.AppendLine("  Code after unconditional return/throw/ExitApp can never execute.")
    [void]$failOutput.AppendLine("  This often indicates logic errors or leftover code from refactoring.")
    [void]$failOutput.AppendLine("  Fix: remove the unreachable code, or restructure the control flow.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: unreachable-code' on the unreachable line.")
    $grouped = $ucIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): unreachable after line $($issue.AfterLine)")
            [void]$failOutput.AppendLine("        $($issue.Text)")
        }
    }
}

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All directive checks passed (requires, singleinstance, state_strings, winexist_cloaked, bare_try, return_paths, unreachable_code)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_directives_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
