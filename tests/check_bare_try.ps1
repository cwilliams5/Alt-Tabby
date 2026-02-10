# check_bare_try.ps1 - Static analysis for AHK v2 bare try statements
# Pre-gate test: runs before any AHK process launches.
# Detects try statements without a matching catch block that silently swallow errors.
# Some patterns are auto-exempt (fire-and-forget cleanup, OnExit handlers, etc.).
#
# Usage: powershell -File tests\check_bare_try.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = issues found

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Helpers ===

# Clean-Line: strip strings and comments for structural parsing (brace counting, keyword detection)
function Clean-Line {
    param([string]$line)
    $cleaned = $line -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace "'[^']*'", "''"
    $cleaned = $cleaned -replace '\s;.*$', ''
    if ($cleaned -match '^\s*;') { return '' }
    return $cleaned
}

# Strip-Comments: remove only comments, preserve string contents for pattern matching
function Strip-Comments {
    param([string]$line)
    $stripped = $line -replace '\s;.*$', ''
    if ($stripped -match '^\s*;') { return '' }
    return $stripped
}

function Test-AutoExempt {
    param([string]$expr)
    $t = $expr.Trim()

    # DllCall cleanup patterns
    if ($t -match '(?i)DllCall\(\s*"[^"]*\\?(DestroyIcon|CloseHandle|DisconnectNamedPipe|FlushFileBuffers|DeleteObject|ReleaseDC|SelectObject|DeleteDC|DeleteFont)"') { return $true }
    # GDI+ native cleanup
    if ($t -match '(?i)DllCall\(\s*"gdiplus\\Gdip(Delete|Dispose|lusShutdown)') { return $true }
    # GDI cleanup
    if ($t -match '(?i)DllCall\(\s*"gdi32\\(DeleteObject|SelectObject|DeleteDC)"') { return $true }
    # DWM calls (best-effort visual effects)
    if ($t -match '(?i)DllCall\(\s*"dwmapi\\Dwm(SetWindowAttribute|Flush)"') { return $true }

    # File operations (fire-and-forget)
    if ($t -match '(?i)^FileDelete\(') { return $true }
    if ($t -match '(?i)^FileCopy\(') { return $true }
    if ($t -match '(?i)^FileMove\(') { return $true }
    if ($t -match '(?i)^FileAppend\(') { return $true }
    if ($t -match '(?i)^DirDelete\(') { return $true }

    # SetTimer with 0 (timer stop)
    if ($t -match '(?i)^SetTimer\(.*,\s*0\s*\)') { return $true }

    # Gdip wrapper cleanup
    if ($t -match '(?i)^Gdip_(Delete|Dispose|Shutdown)') { return $true }

    # Process/window management (target may be gone)
    if ($t -match '(?i)^ProcessClose\(') { return $true }
    if ($t -match '(?i)^WinClose\(') { return $true }
    if ($t -match '(?i)^WinKill\(') { return $true }
    if ($t -match '(?i)^WinActivate\(') { return $true }

    # Window attribute operations (window may have closed)
    if ($t -match '(?i)^WinSet(AlwaysOnTop|Transparent|ExStyle)\b') { return $true }

    # IniWrite/IniRead/IniDelete (config persistence)
    if ($t -match '(?i)^Ini(Write|Read|Delete)\(') { return $true }

    # Registry operations
    if ($t -match '(?i)^Reg(Write|Read|Delete)\(') { return $true }

    # Hotkey registration (may fail if already exists)
    if ($t -match '(?i)^Hotkey\(') { return $true }

    # OnError/OnExit registration
    if ($t -match '(?i)^On(Error|Exit)\(') { return $true }

    # Logging (fire-and-forget)
    if ($t -match '(?i)^LogAppend\(') { return $true }

    # PostMessage (target may be gone)
    if ($t -match '(?i)^PostMessage\(') { return $true }

    # Send (keyboard send, best-effort)
    if ($t -match '(?i)^Send\(') { return $true }

    # GUI object operations (may fail during teardown)
    if ($t -match '(?i)\.(Destroy|Hide|Move|Choose)\(') { return $true }
    if ($t -match '(?i)\.(Value|Text|BackColor)\s*:=') { return $true }

    # Run/RunWait (process launch)
    if ($t -match '(?i)^Run(Wait)?\(') { return $true }

    # Theme cleanup
    if ($t -match '(?i)^Theme_UntrackGui\(') { return $true }
    if ($t -match '(?i)^Theme_ApplyToWindow\(') { return $true }
    if ($t -match '(?i)^HideSplashScreen\(') { return $true }
    if ($t -match '(?i)^GUI_AntiFlashReveal\(') { return $true }

    # Window queries (target window may have closed)
    if ($t -match '(?i)^(WinGetTitle|WinGetClass|WinGetProcessName|WinGetID)\(') { return $true }
    if ($t -match '(?i):= (WinGetTitle|WinGetClass|WinGetProcessName|WinGetID)\(') { return $true }
    if ($t -match '(?i):= WinGetTitle\(') { return $true }

    # DllCall for system API queries (best-effort, may not exist on older Windows)
    if ($t -match '(?i)DllCall\(\s*"(user32|shcore)\\(SetProcess|GetDpi|GetDpiFor|SetWindowLongPtrW|GetWindowLongPtrW)') { return $true }
    # General DllCall used in DPI detection (fire-and-forget fallback chains)
    if ($t -match '(?i)^(hr\s*:=\s*)?DllCall\(') { return $true }

    # WindowStore operations (window may have been removed between check and call)
    if ($t -match '(?i)^WindowStore_(UpdateFields|UpsertWindow|SetCurrentWorkspace|EnqueueIconRefresh|BatchUpdateFields|ValidateExistence|CleanupAllIcons|CleanupExeIconCache|PruneProcNameCache|PruneExeIconCache)\(') { return $true }
    if ($t -match '(?i):= WindowStore_(UpdateFields|GetByHwnd|SetCurrentWorkspace)\(') { return $true }

    # Store operations (best-effort, IPC may be disconnected)
    if ($t -match '(?i)^Store_(PushToClients|BroadcastWorkspaceFlips|LogError|LogInfo)\(') { return $true }
    if ($t -match '(?i)^IPC_PipeClient_Send\(') { return $true }

    # Producer operations (best-effort lifecycle management)
    if ($t -match '(?i)^(IconPump|ProcPump|KomorebiSub|KomorebiLite|WinEventHook|MRU_Lite)_(Stop|EnsureRunning|PruneStaleCache|CleanupWindow|CleanupUwpCache|PruneProcNameCache|PruneExeIconCache|PruneFailedPidCache|Poll)\(') { return $true }

    # JSON parsing (may fail on malformed input)
    if ($t -match '(?i):= JSON\.Load\(') { return $true }
    if ($t -match '(?i)^(parsed|stateObj|obj)\s*:= JSON\.Load\(') { return $true }

    # Type conversions (may fail on non-numeric)
    if ($t -match '(?i)^return Integer\(') { return $true }
    if ($t -match '(?i):= Integer\(') { return $true }
    if ($t -match '(?i):= Float\(') { return $true }

    # FileRead (file may not exist)
    if ($t -match '(?i)^(\w+\s*:=\s*)?FileRead\(') { return $true }
    if ($t -match '(?i):= FileRead\(') { return $true }
    if ($t -match '(?i):= Trim\(FileRead\(') { return $true }

    # Stats operations (best-effort)
    if ($t -match '(?i)^Stats_(FlushToDisk|SendToStore)\(') { return $true }

    # Log operations (fire-and-forget)
    if ($t -match '(?i)^LogInitSession\(') { return $true }

    # Property access on object that may not have the property
    if ($t -match '(?i):= \w+\.\w+$') { return $true }

    # Regex compilation (best-effort pattern validation)
    if ($t -match '(?i):= BL_CompileWildcard\(') { return $true }

    # WebView2 operations (WebView may not be initialized or may have been destroyed)
    if ($t -match '(?i)WebView\.(ExecuteScript|Navigate|add_WebMessageReceived)\(') { return $true }
    if ($t -match '(?i)Controller\.(Fill|DefaultBackgroundColor)') { return $true }
    if ($t -match '(?i)Controller\s*:= 0') { return $true }

    # IPC client connection (best-effort)
    if ($t -match '(?i):= IPC_PipeClient_Connect\(') { return $true }

    # ProcessUtils operations
    if ($t -match '(?i)^ProcessUtils_RunWaitHidden\(') { return $true }

    # Launcher operations
    if ($t -match '(?i)^Launcher_ShutdownSubprocesses\(') { return $true }
    if ($t -match '(?i)^DeleteAdminTask\(') { return $true }
    if ($t -match '(?i)^CL_WriteIniPreserveFormat\(') { return $true }
    if ($t -match '(?i):= CL_WriteIniPreserveFormat\(') { return $true }

    # ThemeMsgBox (best-effort GUI)
    if ($t -match '(?i)^ThemeMsgBox\(') { return $true }

    # GUI Show (window may have been destroyed)
    if ($t -match '(?i)\.(Show)\(') { return $true }

    # Callback invocation (fire-and-forget)
    if ($t -match '(?i)\.Call\(') { return $true }
    if ($t -match '(?i)^callback\(\)') { return $true }

    # FileExist/FileGetSize/FileGetTime/FileGetVersion checks (best-effort)
    if ($t -match '(?i)(FileExist|FileGetSize|FileGetTime|FileGetVersion)\(') { return $true }

    # return MsgBox (best-effort)
    if ($t -match '(?i)^return MsgBox\(') { return $true }

    # General DllCall (all DllCall can fail on edge cases)
    if ($t -match '(?i)DllCall\(') { return $true }

    # Variable assignments from safe operations (fire-and-forget context)
    # Property access on Map/Object that may not have key
    if ($t -match '(?i):= \w+\.\w+\b') { return $true }

    # ComObject operations (COM may not be available)
    if ($t -match '(?i)ComObject\(') { return $true }
    if ($t -match '(?i)\.(ShellExecute|CreateShortcut|Run)\(') { return $true }
    if ($t -match '(?i)\.(RawWrite)\(') { return $true }

    # General control flow inside bare try blocks (multi-statement blocks are inherently wrapped)
    # These are structural elements, not the "call being swallowed"
    if ($t -match '(?i)^(if|else|return|continue|break|global|local|static|Loop|for|while|switch)\b') { return $true }

    # Variable declaration/assignment/increment (part of a larger try block)
    if ($t -match '^\w+\s*:=') { return $true }
    if ($t -match '^\w+\s*\.=') { return $true }
    if ($t -match '^\w+\s*\+=') { return $true }
    if ($t -match '^\w+\+\+') { return $true }
    if ($t -match '^\w+\-\-') { return $true }

    # Map/array access assignment or method call
    if ($t -match '^\w+\[') { return $true }
    if ($t -match '^\w+\.\w+\(') { return $true }

    # Nested try (try statement inside a bare try block)
    if ($t -match '(?i)^try\b') { return $true }

    # Bare function calls that are clearly fire-and-forget
    if ($t -match '(?i)^_?(GUI|Store|Launcher|Viewer|Update|Blacklist|BL|CEN|CEW|CRE|Theme|IPC|WinEnum)') { return $true }
    if ($t -match '(?i)^Sleep\(') { return $true }

    return $false
}

# Find the line where a block starting with `{` closes.
# Uses cleanedLines for brace counting, rawLines for statement content.
# Returns: hashtable with EndLine, HasCatch, Statements (raw text).
function Find-BlockEnd {
    param(
        [string[]]$cleanedLines,
        [string[]]$rawLines,
        [int]$openBraceLine,
        [int]$startDepth
    )

    $result = @{
        EndLine    = -1
        HasCatch   = $false
        Statements = [System.Collections.ArrayList]::new()
    }

    $depth = $startDepth
    for ($ln = $openBraceLine + 1; $ln -lt $cleanedLines.Count; $ln++) {
        $cl = $cleanedLines[$ln]
        if ($cl -eq '') { continue }

        # Process braces character by character to detect when depth first reaches 0
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
                if ($depth -le 0) {
                    $hitZero = $true
                }
            }
        }

        if ($hitZero) {
            $result.EndLine = $ln
            # Check if catch/finally follows on same line after closing brace
            $after = $afterZeroText.Trim()
            if ($after -match '(?i)^(catch|finally)\b') {
                $result.HasCatch = $true
            } else {
                # Check next non-empty line
                for ($m = $ln + 1; $m -lt $cleanedLines.Count; $m++) {
                    $mcl = $cleanedLines[$m]
                    if ($mcl -eq '') { continue }
                    if ($mcl.Trim() -match '(?i)^(catch|finally)\b') {
                        $result.HasCatch = $true
                    }
                    break
                }
            }
            return $result
        }

        # Collect top-level statements (depth 1 = direct children of try block)
        # Use raw line (with comments stripped) for pattern matching
        if ($depthBefore -eq 1) {
            $trimmed = $cl.Trim()
            if ($trimmed -ne '{' -and $trimmed -ne '}') {
                $rawStmt = (Strip-Comments $rawLines[$ln]).Trim()
                if ($rawStmt -ne '') {
                    [void]$result.Statements.Add($rawStmt)
                }
            }
        }
    }
    return $result
}

# === Resolve source directory ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$projectRoot = (Resolve-Path "$SourceDir\..").Path
$files = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })
Write-Host "  Scanning $($files.Count) files for bare try statements..." -ForegroundColor Cyan

$AHK_KEYWORDS = @(
    'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
    'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
    'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
    'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
)

# ============================================================
# Parse each file
# ============================================================
$scanSw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()
$tryCount = 0
$exemptCount = 0

foreach ($file in $files) {
    $rawLines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$projectRoot\", '')

    # Pre-clean all lines for structural parsing
    $cleanedLines = [string[]]::new($rawLines.Count)
    for ($idx = 0; $idx -lt $rawLines.Count; $idx++) {
        $cleanedLines[$idx] = Clean-Line $rawLines[$idx]
    }

    # Pass 1: Identify function boundaries and OnExit handlers
    $onExitRanges = [System.Collections.ArrayList]::new()
    $depth = 0
    $inFunc = $false
    $funcDepth = -1
    $funcStart = -1
    $funcName = ""

    for ($idx = 0; $idx -lt $rawLines.Count; $idx++) {
        $cl = $cleanedLines[$idx]
        if ($cl -eq '') { continue }

        if (-not $inFunc -and $cl -match '^\s*(?:static\s+)?(\w+)\s*\(') {
            $fname = $Matches[1]
            if ($fname.ToLower() -notin $AHK_KEYWORDS -and $cl -match '\{') {
                $inFunc = $true
                $funcName = $fname
                $funcDepth = $depth
                $funcStart = $idx
            }
        }

        foreach ($ch in $cl.ToCharArray()) {
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') { $depth-- }
        }

        if ($inFunc -and $depth -le $funcDepth) {
            if ($funcName -match '(?i)OnExit') {
                [void]$onExitRanges.Add([PSCustomObject]@{ Start = $funcStart; End = $idx })
            }
            $inFunc = $false
            $funcDepth = -1
        }
    }

    # Pass 2: Find try statements
    for ($i = 0; $i -lt $rawLines.Count; $i++) {
        $cl = $cleanedLines[$i]
        if ($cl -eq '') { continue }
        if ($cl -notmatch '^\s*try\b') { continue }

        $tryCount++
        $tryLineNum = $i + 1

        # Check if inside OnExit handler
        $inOnExit = $false
        foreach ($r in $onExitRanges) {
            if ($i -ge $r.Start -and $i -le $r.End) { $inOnExit = $true; break }
        }
        if ($inOnExit) { $exemptCount++; continue }

        # Get text after 'try' keyword on same line (structural, cleaned)
        $afterTry = ($cl -replace '^\s*try\s*', '').Trim()
        # Get raw text after 'try' for auto-exempt matching
        $rawAfterTry = ((Strip-Comments $rawLines[$i]) -replace '^\s*try\s*', '').Trim()

        if ($afterTry -match '^\{') {
            # Block try with `{` on same line
            $initDepth = 0
            foreach ($ch in $afterTry.ToCharArray()) {
                if ($ch -eq '{') { $initDepth++ }
                elseif ($ch -eq '}') { $initDepth-- }
            }

            if ($initDepth -le 0) {
                # Single-line block, check for catch after
                $hasCatch = $false
                for ($j = $i + 1; $j -lt $rawLines.Count; $j++) {
                    $jcl = $cleanedLines[$j]
                    if ($jcl -eq '') { continue }
                    if ($jcl.Trim() -match '(?i)^(catch|finally)\b') { $hasCatch = $true }
                    break
                }
                if ($hasCatch) { continue }
                # Extract content between braces from raw line
                $rawBraceContent = ((Strip-Comments $rawLines[$i]) -replace '^\s*try\s*', '').Trim()
                if ($rawBraceContent -match '^\{(.*)\}\s*$') {
                    $inner = $Matches[1].Trim()
                    if ($inner -ne '' -and -not (Test-AutoExempt $inner)) {
                        [void]$issues.Add([PSCustomObject]@{ File=$relPath; Line=$tryLineNum; Expr=$inner })
                    } else { $exemptCount++ }
                }
                continue
            }

            $block = Find-BlockEnd $cleanedLines $rawLines $i $initDepth
            if ($block.EndLine -lt 0) { continue }
            $i = $block.EndLine

            if ($block.HasCatch) { continue }

            # Bare block try
            if ($block.Statements.Count -eq 0) { continue }
            $allExempt = $true
            foreach ($stmt in $block.Statements) {
                if (-not (Test-AutoExempt $stmt)) { $allExempt = $false; break }
            }
            if ($allExempt) { $exemptCount++; continue }
            foreach ($stmt in $block.Statements) {
                if (-not (Test-AutoExempt $stmt)) {
                    [void]$issues.Add([PSCustomObject]@{ File=$relPath; Line=$tryLineNum; Expr=$stmt })
                }
            }

        } elseif ($afterTry -eq '') {
            # `try` alone — look at next non-empty line
            for ($j = $i + 1; $j -lt $rawLines.Count; $j++) {
                $jcl = $cleanedLines[$j]
                if ($jcl -eq '') { continue }
                $jTrimmed = $jcl.Trim()

                if ($jTrimmed -match '^\{') {
                    # Block try with `{` on next line
                    $initDepth = 0
                    foreach ($ch in $jcl.ToCharArray()) {
                        if ($ch -eq '{') { $initDepth++ }
                        elseif ($ch -eq '}') { $initDepth-- }
                    }

                    if ($initDepth -le 0) {
                        $hasCatch = $false
                        for ($k = $j + 1; $k -lt $rawLines.Count; $k++) {
                            $kcl = $cleanedLines[$k]
                            if ($kcl -eq '') { continue }
                            if ($kcl.Trim() -match '(?i)^(catch|finally)\b') { $hasCatch = $true }
                            break
                        }
                        $i = $j
                        break
                    }

                    $block = Find-BlockEnd $cleanedLines $rawLines $j $initDepth
                    if ($block.EndLine -lt 0) { $i = $j; break }
                    $i = $block.EndLine

                    if ($block.HasCatch) { break }

                    if ($block.Statements.Count -eq 0) { break }
                    $allExempt = $true
                    foreach ($stmt in $block.Statements) {
                        if (-not (Test-AutoExempt $stmt)) { $allExempt = $false; break }
                    }
                    if ($allExempt) { $exemptCount++; break }
                    foreach ($stmt in $block.Statements) {
                        if (-not (Test-AutoExempt $stmt)) {
                            [void]$issues.Add([PSCustomObject]@{ File=$relPath; Line=$tryLineNum; Expr=$stmt })
                        }
                    }
                    break
                } else {
                    # Single-line try — use raw line for pattern matching
                    $rawStmt = (Strip-Comments $rawLines[$j]).Trim()
                    if (Test-AutoExempt $rawStmt) { $exemptCount++ }
                    else {
                        [void]$issues.Add([PSCustomObject]@{ File=$relPath; Line=$tryLineNum; Expr=$rawStmt })
                    }
                    $i = $j
                    break
                }
            }
        } else {
            # Single-line try: `try <expr>` — use raw line for pattern matching
            if (Test-AutoExempt $rawAfterTry) { $exemptCount++ }
            else {
                [void]$issues.Add([PSCustomObject]@{ File=$relPath; Line=$tryLineNum; Expr=$rawAfterTry })
            }
        }
    }
}
$scanSw.Stop()
$totalSw.Stop()

# ============================================================
# Report
# ============================================================
$timingLine = "  Timing: scan=$($scanSw.ElapsedMilliseconds)ms  total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $tryCount try statements, $exemptCount auto-exempt, $($files.Count) files"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) bare try issue(s) found." -ForegroundColor Red
    Write-Host "  These try statements have no catch block and silently swallow errors." -ForegroundColor Red
    Write-Host "  Fix: add a catch block, or if intentional, add the pattern to auto-exempt list." -ForegroundColor Yellow

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host "`n    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            $exprShort = $issue.Expr
            if ($exprShort.Length -gt 80) { $exprShort = $exprShort.Substring(0, 77) + "..." }
            Write-Host "      Line $($issue.Line): try without catch: $exprShort" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: All try statements have catch blocks or are auto-exempt" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
