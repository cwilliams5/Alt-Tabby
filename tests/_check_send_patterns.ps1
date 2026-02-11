# check_send_patterns.ps1 - Send/Hook safety enforcement
# Prevents keyboard hook uninstallation from lost keypresses.
# SendMode("Input") or SendInput temporarily uninstalls ALL keyboard hooks.
# During that window, user keypresses are lost forever.
#
# Rules:
#   1. FORBIDDEN: SendMode("Input") or SendMode("InputThenPlay") in any src/ file
#   2. FORBIDDEN: AHK SendInput command in GUI process files (src/gui/*.ahk)
#      (DllCall("user32\SendInput"...) is exempt - it's a raw Win32 call for foreground stealing)
#   3. REQUIRED: SendMode("Event") must appear in src/gui/gui_main.ahk
#
# Usage: powershell -File tests\check_send_patterns.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = issues found

param(
    [string]$SourceDir,
    [switch]$BatchMode
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Helpers ===
function Clean-Line {
    param([string]$line)
    # Remove quoted strings to avoid false matches on content inside strings
    $cleaned = $line -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace "'[^']*'", "''"
    # Remove full-line comments
    if ($cleaned -match '^\s*;') { return '' }
    # Remove end-of-line comments (semicolon preceded by whitespace)
    $cleaned = $cleaned -replace '\s;.*$', ''
    return $cleaned
}

# === Resolve source directory ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    if ($BatchMode) { return 1 } else { exit 1 }
}

$projectRoot = (Resolve-Path "$SourceDir\..").Path

# ============================================================
# Scan
# ============================================================
$scanSw = [System.Diagnostics.Stopwatch]::StartNew()
$issues = [System.Collections.ArrayList]::new()

$files = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })

$guiMainPath = Join-Path $SourceDir "gui\gui_main.ahk"

# Rule 3: Check that SendMode("Event") exists in gui_main.ahk
$hasSendModeEvent = $false

foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $isGuiFile = $file.FullName -like "*\gui\*"

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $rawLine = $lines[$i]
        $cleaned = Clean-Line $rawLine

        if ($cleaned -eq '') { continue }

        # Check for lint-ignore suppression on raw line
        if ($rawLine -match 'lint-ignore:\s*send-pattern') { continue }

        # Rule 1: Forbidden SendMode("Input") or SendMode("InputThenPlay")
        # Check raw line since Clean-Line strips quoted strings
        if ($rawLine -match 'SendMode\s*\(\s*"(Input|InputThenPlay)"\s*\)') {
            [void]$issues.Add([PSCustomObject]@{
                File    = $relPath
                Line    = $i + 1
                Message = "Forbidden SendMode: $($rawLine.Trim())"
                Rule    = "SendMode"
            })
        }

        # Rule 2: Forbidden AHK SendInput command in gui/ files
        # Match AHK SendInput command: starts with SendInput followed by space, comma, or {
        # Exclude DllCall references (raw Win32 API)
        if ($isGuiFile) {
            # Match standalone SendInput command (not inside a DllCall, not in a comment/string)
            # AHK command form: SendInput "..." or SendInput, ...
            if ($cleaned -match '(?<!\w)SendInput[\s,\(]' -and
                $cleaned -notmatch 'DllCall\(' -and
                $cleaned -notmatch 'SendInput\s*\(' -and  # Function-call style would be DllCall
                $cleaned -notmatch '^\s*;') {
                [void]$issues.Add([PSCustomObject]@{
                    File    = $relPath
                    Line    = $i + 1
                    Message = "SendInput in GUI file (uninstalls keyboard hooks): $($rawLine.Trim())"
                    Rule    = "SendInput"
                })
            }
        }

        # Rule 3: Track SendMode("Event") in gui_main.ahk (check raw line, not cleaned)
        if ($file.FullName -eq $guiMainPath -and $rawLine -match 'SendMode\s*\(\s*"Event"\s*\)') {
            $hasSendModeEvent = $true
        }
    }
}

# Rule 3: Verify SendMode("Event") was found
if (-not $hasSendModeEvent) {
    [void]$issues.Add([PSCustomObject]@{
        File    = "src\gui\gui_main.ahk"
        Line    = 0
        Message = "Missing required SendMode(`"Event`") declaration"
        Rule    = "SendModeEvent"
    })
}

$scanSw.Stop()
$totalSw.Stop()

# ============================================================
# Report
# ============================================================
$timingLine = "  Timing: scan=$($scanSw.ElapsedMilliseconds)ms  total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $($files.Count) files scanned"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) Send/Hook safety issue(s) found." -ForegroundColor Red
    Write-Host "  SendMode(`"Input`") and SendInput uninstall keyboard hooks, causing lost keypresses." -ForegroundColor Red
    Write-Host "  Fix: use SendMode(`"Event`") and avoid raw SendInput in GUI files." -ForegroundColor Yellow
    Write-Host "  Suppress: add '; lint-ignore: send-pattern' on the offending line." -ForegroundColor Yellow

    $grouped = $issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host ""
        Write-Host "    $($group.Name):" -ForegroundColor Yellow
        foreach ($issue in $group.Group | Sort-Object Line) {
            if ($issue.Line -gt 0) {
                Write-Host "      Line $($issue.Line): $($issue.Message)" -ForegroundColor Red
            } else {
                Write-Host "      $($issue.Message)" -ForegroundColor Red
            }
        }
    }

    if ($BatchMode) { return 1 }
    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    if ($BatchMode) { return 0 }
    Write-Host "  PASS: Send/Hook patterns are safe" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
