# check_logging_hygiene.ps1 - Static analysis for logging discipline
# Pre-gate test: runs before any AHK process launches.
# Catches logging anti-patterns:
#   1. Unconditional FileAppend in catch blocks (hardcoded log paths)
#   2. Duplicate *_Log / *_DiagLog function definitions in same file
#   3. Legacy *_DebugLog global variables (should use cfg.Diag* pattern)
#   4. Store_LogError must exist and be intentionally unconditional (no cfg.Diag check)
#
# Usage: powershell -File tests\check_logging_hygiene.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all clear, 1 = issues found

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

# === Check 1: Unconditional FileAppend in catch blocks ===
# Catches: catch { FileAppend(..., A_Temp "\some_file.txt") } without config gating

$check1Files = @(
    "$SourceDir\gui\gui_state.ahk",
    "$SourceDir\store\komorebi_sub.ahk",
    "$SourceDir\shared\ipc_pipe.ahk"
)

$issues = @()

foreach ($filePath in $check1Files) {
    if (-not (Test-Path $filePath)) { continue }
    $content = [System.IO.File]::ReadAllText($filePath)
    $fileName = [System.IO.Path]::GetFileName($filePath)

    # Heuristic: catch block with FileAppend to A_Temp with hardcoded .txt filename
    if ($content -match 'catch[^{]*\{[^}]*FileAppend\([^,]+,\s*A_Temp\s*["\\]+[a-z_]+\.txt') {
        $issues += [PSCustomObject]@{
            Check = 'Unconditional FileAppend'
            File  = $fileName
            Detail = 'FileAppend in catch block writes to hardcoded temp path'
        }
    }
}

# === Check 2: Duplicate *_Log / *_DiagLog function patterns ===
# Each module should have ONE logging function, not both a legacy *_Log and a *_DiagLog

$check2Files = @(
    @{ Path = "$SourceDir\store\komorebi_sub.ahk"; Prefix = '_KSub' },
    @{ Path = "$SourceDir\store\store_server.ahk"; Prefix = 'Store' },
    @{ Path = "$SourceDir\gui\gui_state.ahk";     Prefix = '_GUI' }
)

foreach ($entry in $check2Files) {
    if (-not (Test-Path $entry.Path)) { continue }
    $content = [System.IO.File]::ReadAllText($entry.Path)
    $fileName = [System.IO.Path]::GetFileName($entry.Path)
    $prefix = $entry.Prefix

    $hasLegacyLog = $content -match "${prefix}_Log\s*\([^)]*\)\s*\{"
    $hasDiagLog   = $content -match "${prefix}_DiagLog\s*\([^)]*\)\s*\{"

    if ($hasLegacyLog -and $hasDiagLog) {
        $issues += [PSCustomObject]@{
            Check  = 'Duplicate logging'
            File   = $fileName
            Detail = "Has both ${prefix}_Log and ${prefix}_DiagLog (should unify)"
        }
    }
}

# === Check 3: Legacy *_DebugLog global variables ===
# These should be replaced with config-gated logging using cfg.Diag* options

$allAhkFiles = @(Get-ChildItem -Path $SourceDir -Recurse -Filter '*.ahk')

foreach ($file in $allAhkFiles) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        # Skip comment-only lines
        if ($line -match '^\s*;') { continue }
        # Match: global SomeThing_DebugLog :=
        if ($line -match 'global\s+\w+_DebugLog\s*:=') {
            $relPath = $file.FullName
            if ($relPath.StartsWith($SourceDir)) {
                $relPath = $relPath.Substring($SourceDir.Length).TrimStart('\', '/')
            }
            $issues += [PSCustomObject]@{
                Check  = 'Legacy DebugLog'
                File   = $relPath
                Detail = "Line $($i + 1): legacy *_DebugLog variable (convert to cfg.Diag* pattern)"
            }
        }
    }
}

# === Check 4: Store_LogError must be unconditional ===
# Store_LogError is for fatal errors and must NOT have a cfg.Diag* gate

$storeServerPath = "$SourceDir\store\store_server.ahk"
if (Test-Path $storeServerPath) {
    $content = [System.IO.File]::ReadAllText($storeServerPath)

    $hasLogError = $content -match 'Store_LogError\(msg\)'
    if (-not $hasLogError) {
        $issues += [PSCustomObject]@{
            Check  = 'Store_LogError missing'
            File   = 'store_server.ahk'
            Detail = 'Store_LogError(msg) function not found'
        }
    } else {
        # Extract function body and check for cfg.Diag (should NOT be present)
        if ($content -match 'Store_LogError\(msg\)\s*\{([^}]+)\}') {
            $funcBody = $Matches[1]
            if ($funcBody -match 'cfg\.Diag') {
                $issues += [PSCustomObject]@{
                    Check  = 'Store_LogError gated'
                    File   = 'store_server.ahk'
                    Detail = 'Store_LogError should be unconditional (no cfg.Diag check)'
                }
            }
        }
    }
}

$totalSw.Stop()

# === Report ===

$timingLine = "  Timing: total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $($allAhkFiles.Count) files scanned, $($issues.Count) issue(s)"

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($issues.Count) logging hygiene issue(s) detected." -ForegroundColor Red

    foreach ($issue in $issues) {
        Write-Host "    [$($issue.Check)] $($issue.File): $($issue.Detail)" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  PASS: No logging hygiene issues detected" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
