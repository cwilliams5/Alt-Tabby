# check_warn.ps1 - Detect AHK v2 VarUnset warnings via temp-load approach
#
# Creates a temp mirror of src/ with #Warn VarUnset, Off stripped, then loads
# all production code with #Warn VarUnset, StdOut to detect variables that are
# used but never assigned. These would appear as blocking dialog popups during
# normal operation (without /ErrorStdOut).
#
# How it works:
#   1. Copies all src/*.ahk to a temp directory, stripping #Warn VarUnset, Off
#      (lib/ files copied as-is — needed for function resolution, not checked)
#   2. Parses alt_tabby.ahk for #Include directives to auto-generate wrapper
#      (include chain can never drift from production)
#   3. Runs the wrapper with /ErrorStdOut to capture load-time warnings
#   4. Parses stdout for VarUnset warning patterns
#   5. Maps temp paths back to real source paths for readable output
#
# Usage: powershell -File tests\check_warn.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = warnings detected

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# === Resolve paths ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

# Find AutoHotkey v2
$ahkExe = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
if (-not (Test-Path $ahkExe)) {
    Write-Host "  SKIP: AutoHotkey v2 not found at expected path" -ForegroundColor Yellow
    exit 0  # Don't block if AHK not installed
}

# === Create temp mirror of src/ ===
$tempRoot = Join-Path $env:TEMP "tabby_warn_check_$PID"
if (Test-Path $tempRoot) { Remove-Item -Recurse -Force $tempRoot }

$srcDest = Join-Path $tempRoot "src"
$strippedCount = 0
$fileCount = 0

# Copy ALL src/ files including lib/ (needed for function resolution).
# Strip #Warn VarUnset, Off from non-lib files only.
foreach ($file in Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse) {
    $relPath = $file.FullName.Substring($SourceDir.Length)
    $destPath = Join-Path $srcDest $relPath
    $destDir = Split-Path $destPath -Parent
    if (-not (Test-Path $destDir)) { [void](New-Item -ItemType Directory -Path $destDir -Force) }

    $content = [System.IO.File]::ReadAllText($file.FullName)

    # Only strip #Warn from non-lib files (lib/ is third-party, don't check)
    if ($file.FullName -notlike "*\lib\*") {
        $modified = $content -replace '(?m)^#Warn\s+VarUnset\s*,\s*Off[^\r\n]*', '; [check_warn: #Warn stripped for analysis]'
        if ($modified -ne $content) { $strippedCount++ }
        [System.IO.File]::WriteAllText($destPath, $modified, [System.Text.UTF8Encoding]::new($false))
        $fileCount++
    } else {
        [System.IO.File]::WriteAllText($destPath, $content, [System.Text.UTF8Encoding]::new($false))
    }
}

# === Auto-generate include chain from alt_tabby.ahk ===
# Parse production entry point for #Include directives so the wrapper
# can never drift from the actual include chain.
$entryPoint = Join-Path $SourceDir "alt_tabby.ahk"
if (-not (Test-Path $entryPoint)) {
    Write-Host "  ERROR: Entry point not found: $entryPoint" -ForegroundColor Red
    exit 1
}

$includeLines = [System.Collections.ArrayList]::new()
$inIncludes = $false
foreach ($line in Get-Content $entryPoint) {
    $trimmed = $line.Trim()
    # Start capturing at the INCLUDES section
    if ($trimmed -match '^\s*;\s*INCLUDES') { $inIncludes = $true; continue }
    if (-not $inIncludes) { continue }
    # Stop at first non-include, non-comment, non-blank line (function/code starts)
    if ($trimmed -and $trimmed -notmatch '^#Include' -and $trimmed -notmatch '^\s*;') { break }
    # Capture #Include lines, transforming paths for wrapper layout
    if ($trimmed -match '^#Include') {
        # Directory switches: %A_ScriptDir%\X\ → %A_ScriptDir%\src\X\
        $transformed = $trimmed -replace '%A_ScriptDir%\\', '%A_ScriptDir%\src\'
        # Strip @profile comments from profiler include
        $transformed = $transformed -replace '\s*;\s*@profile\s*$', ''
        # Make all file includes optional (*i) to prevent hard failures
        # from runtime init issues (we only care about load-time #Warn output).
        # Directory switches (ending with \) stay as-is.
        if ($transformed -match '^#Include\s+[^*]' -and $transformed -notmatch '\\$') {
            $transformed = $transformed -replace '^#Include\s+', '#Include *i '
        }
        [void]$includeLines.Add($transformed)
    }
}

if ($includeLines.Count -eq 0) {
    Write-Host "  ERROR: No #Include directives found in alt_tabby.ahk" -ForegroundColor Red
    exit 1
}

# === Generate wrapper script ===
# Preamble sets test mode globals and #Warn VarUnset, StdOut.
# Include chain is auto-generated from production entry point.
$includeBlock = $includeLines -join "`r`n"

$wrapper = @"
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn VarUnset, StdOut
A_IconHidden := true

; Suppress runtime errors - we only care about load-time #Warn output.
; Production file-scope code may error without full init; that's expected.
OnError((*) => ExitApp(0))

; --- Testing mode flags (prevent auto-initialization in included files) ---
global g_TestingMode := true
global gStore_TestMode := false
global g_AltTabbyMode := "test"

; --- Stats globals (referenced by store code) ---
global gStats_Lifetime := Map()
global gStats_Session := Map()

; --- Dashboard/Update check globals (from launcher_about.ahk) ---
global g_LastUpdateCheckTick := 0
global g_LastUpdateCheckTime := ""
global g_DashUpdateState
g_DashUpdateState := {status: "unchecked", version: "", downloadUrl: ""}

; --- Launcher subprocess PID globals ---
global g_GuiPID := 0
global g_ConfigEditorPID := 0
global g_BlacklistEditorPID := 0

; --- Entry-point globals (set by alt_tabby.ahk mode-switching, not included here) ---
global g_SkipMismatchCheck := false
global g_SkipActiveMutex := false

; --- Include chain (auto-generated from alt_tabby.ahk — do not edit) ---
$includeBlock

ExitApp 0
"@

$wrapperPath = Join-Path $tempRoot "wrapper.ahk"
[System.IO.File]::WriteAllText($wrapperPath, $wrapper, [System.Text.UTF8Encoding]::new($false))

# === Run wrapper and capture output ===
$outFile = Join-Path $tempRoot "stdout.txt"
$errFile = Join-Path $tempRoot "stderr.txt"

# Write a temp .bat to handle quoting reliably (AHK path has spaces)
$batFile = Join-Path $tempRoot "run.bat"
$batContent = "@`"$ahkExe`" /ErrorStdOut `"$wrapperPath`" 1>`"$outFile`" 2>`"$errFile`""
[System.IO.File]::WriteAllText($batFile, $batContent)

$proc = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c", "`"$batFile`"" `
    -NoNewWindow -PassThru

$handle = $proc.Handle  # Cache handle before process exits
$timedOut = $false
try {
    $proc | Wait-Process -Timeout 30
} catch {
    $timedOut = $true
    try { $proc | Stop-Process -Force } catch {}
}

# === Parse output for warnings ===
$stdout = if (Test-Path $outFile) { Get-Content $outFile -Raw -ErrorAction SilentlyContinue } else { "" }
$stderr = if (Test-Path $errFile) { Get-Content $errFile -Raw -ErrorAction SilentlyContinue } else { "" }

# Combine all output - warnings can appear in either stream
$allOutput = "$stdout`n$stderr"

$warnings = [System.Collections.ArrayList]::new()
$lines = $allOutput -split "`r?`n"
for ($i = 0; $i -lt $lines.Count; $i++) {
    $trimmed = $lines[$i].Trim()
    if (-not $trimmed) { continue }

    # Match AHK v2 VarUnset warning patterns:
    #   "Warning:  This local variable appears to never be assigned a value."
    #   "Warning:  This local variable has the same name as a global variable."
    if ($trimmed -match 'Warning:.*never.*assigned' -or
        $trimmed -match 'Warning:.*same name as a global') {
        # Map temp paths back to real source paths for readable output
        $mapped = $trimmed -replace [regex]::Escape($srcDest), $SourceDir

        # Check next line for "Specifically: varName" detail
        $varName = ""
        if ($i + 1 -lt $lines.Count) {
            $nextLine = $lines[$i + 1].Trim()
            if ($nextLine -match 'Specifically:\s*(.+)') {
                $varName = $Matches[1].Trim()
                $i++  # Skip the detail line
            }
        }

        # Skip warnings from lib/ files (third-party code)
        if ($mapped -match '\\lib\\') { continue }

        if ($varName) {
            [void]$warnings.Add("$mapped  [var: $varName]")
        } else {
            [void]$warnings.Add($mapped)
        }
    }
}

# === Cleanup ===
Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue

$sw.Stop()

# === Report ===
if ($timedOut) {
    Write-Host "  WARN: AHK process timed out (30s)" -ForegroundColor Yellow
}

if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($warnings.Count) AHK VarUnset warning(s) detected." -ForegroundColor Red
    Write-Host "  These appear as blocking dialog popups when running without /ErrorStdOut." -ForegroundColor Red
    Write-Host "  Fix: Add 'global <name>' declaration, or correct the variable reference." -ForegroundColor Yellow
    Write-Host ""
    foreach ($w in $warnings) {
        Write-Host "    $w" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Timing: $($sw.ElapsedMilliseconds)ms ($fileCount files, $strippedCount #Warn stripped)" -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: No VarUnset warnings detected ($fileCount files checked)" -ForegroundColor Green
    Write-Host "  Timing: $($sw.ElapsedMilliseconds)ms ($strippedCount #Warn directives stripped)" -ForegroundColor Cyan
    exit 0
}
