# check_warn.ps1 - Detect AHK v2 VarUnset warnings via temp-load approach
#
# Creates a temp mirror of src/ with #Warn VarUnset, Off stripped, then loads
# all production code with #Warn VarUnset, StdOut to detect variables that are
# used but never assigned. These would appear as blocking dialog popups during
# normal operation (without /ErrorStdOut).
#
# How it works:
#   1. Copies all src/*.ahk to a temp directory, stripping #Warn VarUnset, Off
#   2. Creates a wrapper.ahk that sets #Warn VarUnset, StdOut and includes
#      all production files (same include chain as run_tests.ahk)
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

foreach ($file in Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse | Where-Object { $_.FullName -notlike "*\lib\*" }) {
    $relPath = $file.FullName.Substring($SourceDir.Length)
    $destPath = Join-Path $srcDest $relPath
    $destDir = Split-Path $destPath -Parent
    if (-not (Test-Path $destDir)) { [void](New-Item -ItemType Directory -Path $destDir -Force) }

    $content = [System.IO.File]::ReadAllText($file.FullName)
    # Strip #Warn VarUnset, Off (the last directive wins in AHK, so removing these
    # lets our wrapper's #Warn VarUnset, StdOut take effect for all code)
    $modified = $content -replace '(?m)^#Warn\s+VarUnset\s*,\s*Off[^\r\n]*', '; [check_warn: #Warn stripped for analysis]'
    if ($modified -ne $content) { $strippedCount++ }
    [System.IO.File]::WriteAllText($destPath, $modified, [System.Text.UTF8Encoding]::new($false))
    $fileCount++
}

# === Generate wrapper script ===
# Mirrors run_tests.ahk's globals + include chain but exits immediately.
# The load phase triggers AHK's "local variable appears to never be assigned" warnings.
$wrapper = @'
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

; --- Include ALL production files (same order as alt_tabby.ahk) ---
; Full include chain eliminates false positives from cross-file function refs.
; Uses same directory layout: wrapper is at temp/, includes at temp/src/.

; Shared utilities
#Include %A_ScriptDir%\src\shared\
#Include config_loader.ahk
#Include cjson.ahk
#Include ipc_pipe.ahk
#Include blacklist.ahk
#Include setup_utils.ahk
#Include process_utils.ahk
#Include win_utils.ahk
#Include *i pump_utils.ahk
#Include stats.ahk
#Include window_list.ahk

; Editors
#Include %A_ScriptDir%\src\editors\
#Include *i config_editor.ahk
#Include *i blacklist_editor.ahk

; Launcher (full)
#Include %A_ScriptDir%\src\launcher\
#Include *i launcher_utils.ahk
#Include *i launcher_splash.ahk
#Include *i launcher_shortcuts.ahk
#Include *i launcher_install.ahk
#Include *i launcher_wizard.ahk
#Include *i launcher_about.ahk
#Include *i launcher_stats.ahk
#Include *i launcher_tray.ahk
#Include *i launcher_main.ahk

; Core producers (data layer)
#Include %A_ScriptDir%\src\core\
#Include winenum_lite.ahk
#Include *i mru_lite.ahk
#Include *i komorebi_lite.ahk
#Include komorebi_sub.ahk
#Include icon_pump.ahk
#Include *i proc_pump.ahk
#Include *i winevent_hook.ahk

; Viewer
#Include %A_ScriptDir%\src\viewer\
#Include *i viewer.ahk

; GUI
#Include %A_ScriptDir%\src\gui\
#Include *i gui_gdip.ahk
#Include *i gui_win.ahk
#Include *i gui_overlay.ahk
#Include *i gui_workspace.ahk
#Include *i gui_paint.ahk
#Include *i gui_input.ahk
#Include *i gui_data.ahk
#Include *i gui_state.ahk
#Include *i gui_interceptor.ahk
#Include *i gui_main.ahk

ExitApp 0
'@

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
