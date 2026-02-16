# check_includes.ps1 - Verify all source files are reachable via #Include chain
#
# Parses the #Include tree starting from alt_tabby.ahk and flags any .ahk file
# in src/ subdirectories (excluding lib/) that is NOT included. Catches the bug
# class where a new file is added to a subdirectory but forgotten in the entry
# point's include list — the *i fallback silently fails at runtime due to
# %A_ScriptDir% resolving to a different directory.
#
# Usage: powershell -File tests\check_includes.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all pass, 1 = any file orphaned

param(
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'

# === Resolve source directory ===
if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    exit 1
}

$entryPoint = Join-Path $SourceDir "alt_tabby.ahk"
if (-not (Test-Path $entryPoint)) {
    Write-Host "  ERROR: Entry point not found: $entryPoint" -ForegroundColor Red
    exit 1
}

# === Build include tree ===
# Tracks which files are reachable via non-*i includes (mandatory chain).
# Also follows *i includes into files that DO exist, since those files'
# own non-*i includes are part of the chain.
$includedFiles = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$visited = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

function Resolve-IncludeTree {
    param(
        [string]$FilePath,
        [string]$BaseDir  # Current #Include <Dir> context
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path $resolvedPath)) { return }
    if ($visited.Contains($resolvedPath)) { return }
    [void]$visited.Add($resolvedPath)
    [void]$includedFiles.Add($resolvedPath)

    $fileDir = [System.IO.Path]::GetDirectoryName($resolvedPath)
    $currentBase = $BaseDir

    $lines = [System.IO.File]::ReadAllLines($resolvedPath)
    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        # Skip comments
        if ($trimmed.StartsWith(";")) { continue }

        # Match #Include directives
        if ($trimmed -match '^#Include\s+(\*i\s+)?(.+)$') {
            $isOptional = $Matches[1] -ne $null -and $Matches[1].Trim() -ne ""
            $target = $Matches[2].Trim()

            # Strip inline comments (e.g., "#Include file.ahk  ; comment")
            $semiIdx = $target.IndexOf(";")
            if ($semiIdx -ge 0) {
                $target = $target.Substring(0, $semiIdx).Trim()
            }

            # Handle #Include <Dir>\ — changes the include base directory
            # Pattern: path ending with \ (directory change)
            if ($target -match '\\$' -or $target -match '/$') {
                # Resolve the directory path
                $dirTarget = $target
                $dirTarget = $dirTarget -replace '%A_ScriptDir%', $script:scriptDir
                $dirTarget = $dirTarget.TrimEnd('\', '/')
                $resolvedDir = if ([System.IO.Path]::IsPathRooted($dirTarget)) {
                    $dirTarget
                } else {
                    Join-Path $currentBase $dirTarget
                }
                if (Test-Path $resolvedDir) {
                    $currentBase = [System.IO.Path]::GetFullPath($resolvedDir)
                }
                continue
            }

            # Resolve %A_ScriptDir% in file targets
            $target = $target -replace '%A_ScriptDir%', $script:scriptDir

            # Strip quotes
            $target = $target.Trim('"', "'")

            # Resolve path
            $resolvedTarget = if ([System.IO.Path]::IsPathRooted($target)) {
                $target
            } else {
                Join-Path $currentBase $target
            }

            if (Test-Path $resolvedTarget) {
                $resolvedTarget = [System.IO.Path]::GetFullPath($resolvedTarget)
                # Recurse into the included file (whether *i or not — if it exists, its contents matter)
                Resolve-IncludeTree -FilePath $resolvedTarget -BaseDir $currentBase
            }
            # If *i and file doesn't exist: that's OK (intentionally optional like version_info.ahk)
            # If non-*i and file doesn't exist: AHK would error at load time, not our problem here
        }
    }
}

# A_ScriptDir for the entry point = the entry point's directory
$script:scriptDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($entryPoint))

Resolve-IncludeTree -FilePath $entryPoint -BaseDir $script:scriptDir

# === Standalone scripts (launched as separate processes, not #Included) ===
# These are intentionally not in the include chain — they run independently.
$standaloneScripts = @(
    "editors\config_registry_editor.ahk"   # Standalone editor launched via Run()
)

# === Collect all source files in src/ subdirectories (excluding lib/) ===
$sourceFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object {
        $_.FullName -notlike "*\lib\*" -and        # Exclude third-party libs
        $_.DirectoryName -ne $SourceDir             # Exclude files in src/ root (version_info.ahk etc.)
    })

# Filter out known standalone scripts
$sourceFiles = @($sourceFiles | Where-Object {
    $relPath = $_.FullName.Replace("$SourceDir\", "")
    $relPath -notin $standaloneScripts
})

# === Check for orphaned files ===
$orphaned = @()
foreach ($f in $sourceFiles) {
    $fullPath = [System.IO.Path]::GetFullPath($f.FullName)
    if (-not $includedFiles.Contains($fullPath)) {
        $relPath = $f.FullName.Replace("$SourceDir\", "")
        $orphaned += $relPath
    }
}

# === Report ===
if ($orphaned.Count -gt 0) {
    Write-Host "  FAIL: $($orphaned.Count) source file(s) not reachable from alt_tabby.ahk include chain:" -ForegroundColor Red
    foreach ($f in $orphaned | Sort-Object) {
        Write-Host "    ORPHANED: $f" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Fix: Add a #Include directive in alt_tabby.ahk (or a file it includes)." -ForegroundColor Yellow
    Write-Host "  Note: #Include *i with %A_ScriptDir% resolves to the MAIN script's dir," -ForegroundColor Yellow
    Write-Host "        not the including file's dir. Files only reachable via *i are fragile." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "  Include chain: all $($sourceFiles.Count) source files reachable [PASS]" -ForegroundColor Green
    exit 0
}
