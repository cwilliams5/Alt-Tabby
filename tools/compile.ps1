# ============================================================
# Alt-Tabby Compile Script (PowerShell)
# ============================================================
# Compiles alt_tabby.ahk to release/AltTabby.exe
# Usage: compile.ps1 [--test-mode] [--timing] [--force] [--profile]
#   --test-mode   Skip process killing and docs generation, suppress banners
#   --timing      Output machine-readable per-step timing (TIMING:step:ms)
#   --force       Force recompilation even if exe is up to date
#   --profile     Keep ; @profile markers (instrumented build). Without this
#                 flag, all lines ending with ; @profile are stripped.
# ============================================================

param(
    [Alias("test-mode")]
    [switch]$testMode,
    [switch]$timing,
    [switch]$force,
    [switch]$profile
)

# --- Project root (script lives in tools/, project root is one level up) ---
$projectRoot = (Resolve-Path "$PSScriptRoot\..").Path

# --- Timing Infrastructure ---
# Uses Stopwatch for millisecond precision (no batch %TIME% parsing needed)
$stepSw = [System.Diagnostics.Stopwatch]::new()

function Reset-StepTimer { $script:stepSw.Restart() }
function Record-Step {
    param([string]$Label)
    $script:stepSw.Stop()
    if ($script:timing) {
        Write-Output "TIMING:${Label}:$($script:stepSw.ElapsedMilliseconds)"
    }
}

# --- Helpers ---
# Resolve a path through junctions/symlinks by walking up looking for reparse points.
# The junction may be on EITHER side (process reports C:\Users\...\Documents which is
# a junction to E:\Documents, or vice versa). Resolves the path from junction source
# to junction target so both sides can be compared.
function Resolve-ThroughJunctions {
    param([string]$Path)
    try {
        $item = Get-Item $Path -ErrorAction Stop
        $parts = @()
        $current = $item
        while ($current) {
            if ($current.LinkType -and $current.Target) {
                $target = if ($current.Target -is [array]) { $current.Target[0] } else { $current.Target }
                if ($parts.Count -gt 0) {
                    return Join-Path $target ($parts -join [IO.Path]::DirectorySeparatorChar)
                }
                return $target
            }
            $parts = @($current.Name) + $parts
            $current = $current.Parent
        }
    } catch {}
    return $Path
}

# Find AltTabby processes from THIS release directory.
# Handles junctions/symlinks by resolving process paths AND our directory path,
# then comparing all combinations.
function Find-BlockingProcesses {
    param([string]$Dir)
    $resolvedDir = Resolve-ThroughJunctions $Dir
    return Get-Process -Name "AltTabby" -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                if (-not $_.Path) { return $false }
                $procDir = [IO.Path]::GetDirectoryName($_.Path)
                $resolvedProcDir = Resolve-ThroughJunctions $procDir
                # Compare all combinations: raw vs raw, raw vs resolved, resolved vs raw, resolved vs resolved
                $procDir.StartsWith($Dir, [System.StringComparison]::OrdinalIgnoreCase) -or
                $resolvedProcDir.StartsWith($Dir, [System.StringComparison]::OrdinalIgnoreCase) -or
                $procDir.StartsWith($resolvedDir, [System.StringComparison]::OrdinalIgnoreCase) -or
                $resolvedProcDir.StartsWith($resolvedDir, [System.StringComparison]::OrdinalIgnoreCase)
            }
            catch { $false }
        }
}

# --- Locate tools ---
$ahk2exe = "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe"
$ahk2base = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

if (-not (Test-Path $ahk2exe)) {
    Write-Output "ERROR: Ahk2Exe.exe not found at: $ahk2exe"
    Write-Output "Please install AutoHotkey with the compiler component."
    exit 1
}
if (-not (Test-Path $ahk2base)) {
    Write-Output "ERROR: AutoHotkey v2 not found at: $ahk2base"
    Write-Output "Please install AutoHotkey v2."
    exit 1
}

if (-not $testMode) {
    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Alt-Tabby Compiler"
    Write-Output "============================================================"
    Write-Output ""
    Write-Output "Found compiler: $ahk2exe"
    Write-Output "Found v2 base:  $ahk2base"
    Write-Output ""
}

# --- Read version ---
$versionFile = Join-Path $projectRoot "VERSION"
$version = Get-Content $versionFile -ErrorAction SilentlyContinue | Select-Object -First 1
if ($version) { $version = $version.Trim() }
if (-not $version) {
    Write-Output "ERROR: Could not read VERSION file"
    exit 1
}

if (-not $testMode) {
    Write-Output "Version: $version"
    Write-Output ""
}

# --- Generate config documentation (smart skip) ---
# In test mode: skip entirely (not needed for testing)
# In normal mode: skip if options.md is newer than both source files
# --force overrides the smart skip (but not test mode)
Reset-StepTimer
$docsLabel = "Docs"

if ($testMode) {
    $docsLabel = "Docs (skipped)"
} else {
    $docsNeeded = $true
    $docsFile = Join-Path $projectRoot "docs\options.md"
    $configSrc = Join-Path $projectRoot "src\shared\config_registry.ahk"
    $docsBuildScript = Join-Path $PSScriptRoot "build-config-docs.ahk"

    if (-not $force -and (Test-Path $docsFile)) {
        $docsTime = (Get-Item $docsFile).LastWriteTime
        $src1Time = (Get-Item $configSrc).LastWriteTime
        $src2Time = (Get-Item $docsBuildScript).LastWriteTime
        if ($docsTime -gt $src1Time -and $docsTime -gt $src2Time) {
            $docsNeeded = $false
            $docsLabel = "Docs (cached)"
        }
    }

    if (-not $docsNeeded) {
        Write-Output "Config documentation up to date - skipping generation"
        Write-Output ""
    } else {
        Write-Output "Generating config documentation..."
        $docsProc = Start-Process -FilePath $ahk2base -ArgumentList "/ErrorStdOut `"$docsBuildScript`"" -Wait -PassThru -WindowStyle Hidden
        if ($docsProc.ExitCode -ne 0) {
            Write-Output "ERROR: Failed to generate config documentation"
            exit 1
        }
        if (-not (Test-Path $docsFile)) {
            Write-Output "ERROR: docs\options.md was not created"
            exit 1
        }
        Write-Output "  - Generated docs\options.md"
        Write-Output ""
    }
}
Record-Step $docsLabel

# --- Generate AGENTS.MD (smart skip) ---
# Consolidates CLAUDE.md + .claude/rules/ for non-Claude AI agents
Reset-StepTimer
$agentsLabel = "Agents"

if ($testMode) {
    $agentsLabel = "Agents (skipped)"
} else {
    $agentsBuildScript = Join-Path $PSScriptRoot "build-agents-md.ps1"
    $agentsCallArgs = @{}
    if ($force) { $agentsCallArgs['force'] = $true }
    & $agentsBuildScript @agentsCallArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Output "ERROR: Failed to generate AGENTS.MD"
        exit 1
    }
}
Record-Step $agentsLabel

# --- Generate version_info.ahk with Ahk2Exe directives ---
# Always regenerated (content depends on VERSION file, essentially free)
Reset-StepTimer
$versionInfoPath = Join-Path $projectRoot "src\version_info.ahk"
$versionInfoLines = @(
    "; Auto-generated by tools/compile.ps1 - DO NOT EDIT"
    "; Version read from VERSION file"
    ";@Ahk2Exe-SetProductVersion $version"
    ";@Ahk2Exe-SetFileVersion ${version}.0"
)
[IO.File]::WriteAllLines($versionInfoPath, $versionInfoLines)
Record-Step "Version Stamp"

# --- Shader pipeline: bundle + compile ---
# Both scripts have internal staleness checks — fast (~50ms) when nothing changed.
# Invoked inline (& operator) to avoid subprocess startup overhead.
Reset-StepTimer
$shaderBundleScript = Join-Path $PSScriptRoot "shader_bundle.ps1"
$shaderCompileScript = Join-Path $PSScriptRoot "shader_compile.ps1"

# Step 1: shader_bundle.ps1 — generates metadata bundle + resource directives
if (Test-Path $shaderBundleScript) {
    $bundleArgs = @{}
    if ($force) { $bundleArgs['force'] = $true }
    & $shaderBundleScript @bundleArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Output ""
        Write-Output "============================================================"
        Write-Output "ERROR: Shader bundling failed!"
        Write-Output "============================================================"
        exit 1
    }
}
Record-Step "Shader Bundle"

# Step 2: shader_compile.ps1 — compiles HLSL to DXBC bytecode
Reset-StepTimer
if (Test-Path $shaderCompileScript) {
    $compileArgs = @{}
    if ($force) { $compileArgs['force'] = $true }
    & $shaderCompileScript @compileArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Output ""
        Write-Output "============================================================"
        Write-Output "ERROR: Shader compilation failed!"
        Write-Output "See output above for details."
        Write-Output "============================================================"
        exit 1
    }
}
Record-Step "Shader Compile"

if (-not $testMode) {
    Write-Output ""
}

# --- Strip ; @profile markers (unless --profile) ---
# Copies src/ to temp, strips lines ending with ; @profile, compiles from temp.
# With --profile: compiles directly from src/ (instrumented build).
Reset-StepTimer
$stripLabel = "Profile Strip"
$profileTempDir = ""

if ($profile) {
    $stripLabel = "Profile Strip (kept)"
    if (-not $testMode) {
        Write-Output "Profile mode: keeping ; @profile markers (instrumented build)"
        Write-Output ""
    }
} else {
    $profileTempDir = Join-Path ([IO.Path]::GetTempPath()) "alttabby_compile_$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    # Copy src/ tree to temp
    Copy-Item -Path (Join-Path $projectRoot "src") -Destination (Join-Path $profileTempDir "src") -Recurse -Force
    # Junction for resources/ (Ahk2Exe @AddResource uses ../resources relative to src/)
    $resSrc = Join-Path $projectRoot "resources"
    if (Test-Path $resSrc) {
        cmd /c "mklink /J `"$(Join-Path $profileTempDir 'resources')`" `"$resSrc`"" >$null 2>&1
    }

    # Strip all lines ending with ; @profile
    $strippedCount = 0
    Get-ChildItem (Join-Path $profileTempDir "src") -Filter "*.ahk" -Recurse | ForEach-Object {
        $content = [IO.File]::ReadAllText($_.FullName)
        $stripped = $content -replace '(?m)^[^\r\n]*; @profile\s*$\r?\n?', ''
        if ($stripped.Length -ne $content.Length) {
            [IO.File]::WriteAllText($_.FullName, $stripped)
            $strippedCount++
        }
    }
    if (-not $testMode) {
        Write-Output "Stripped ; @profile markers from $strippedCount file(s)"
        Write-Output ""
    }
}
Record-Step $stripLabel

# --- Setup paths ---
$releaseDir = Join-Path $projectRoot "release"
$realSrcDir = Join-Path $projectRoot "src"
# When stripping, compile from the temp copy; otherwise from real src/
$scriptDir = if ($profileTempDir) { Join-Path $profileTempDir "src" } else { $realSrcDir }
$inputFile = Join-Path $scriptDir "alt_tabby.ahk"
$outputFile = Join-Path $releaseDir "AltTabby.exe"
$iconFile = Join-Path $projectRoot "resources\img\icon.ico"

if (-not (Test-Path $releaseDir)) {
    New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
}

if (-not (Test-Path $inputFile)) {
    Write-Output "ERROR: Source file not found: $inputFile"
    exit 1
}

if (-not $testMode) {
    Write-Output "Compiling: $inputFile"
    Write-Output "Output:    $outputFile"
    Write-Output "Base:      $ahk2base"
    Write-Output ""
}

# --- Smart exe skip: check if exe is newer than all source files ---
# Compares exe timestamp against: src\*.ahk (excluding version_info.ahk),
# VERSION file, and icon. Skips recompilation if exe is newer than all.
# version_info.ahk is excluded because we regenerate it every run; VERSION
# file changes are caught explicitly.
# Native PowerShell — no subprocess needed (~0ms vs ~300ms in batch)
$exeNeeded = $true
$exeLabel = "Ahk2Exe"

if (-not $force -and (Test-Path $outputFile)) {
    $exeTime = (Get-Item $outputFile).LastWriteTime
    $srcFiles = @(Get-ChildItem -Path $realSrcDir -Filter "*.ahk" -Recurse |
                  Where-Object { $_.Name -ne "version_info.ahk" })
    $resDir = Join-Path $projectRoot "resources"
    $resFiles = @()
    if (Test-Path $resDir) {
        $resFiles = @(Get-ChildItem -Path $resDir -Recurse -File -ErrorAction SilentlyContinue)
    }
    $checkItems = $srcFiles + $resFiles + @(Get-Item $versionFile)
    if (Test-Path $iconFile) {
        $checkItems += Get-Item $iconFile
    }
    $newest = $checkItems | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($exeTime -gt $newest.LastWriteTime) {
        $exeNeeded = $false
        $exeLabel = "Ahk2Exe (cached)"
    }
}

if (-not $exeNeeded -and -not $testMode) {
    Write-Output "Compilation skipped - exe is newer than source"
    Write-Output "      Use --force to override"
    Write-Output ""
}

# --- Kill AltTabby processes from THIS release directory only ---
# Scoped by path to avoid killing user's personal instance or other worktrees' test processes.
# Skipped when: test mode (test runner handles it) OR exe cached (nothing to write)
if ($exeNeeded -and -not $testMode) {
    Reset-StepTimer
    Write-Output "Checking for running AltTabby processes in $releaseDir..."
    $running = Find-BlockingProcesses $releaseDir
    if ($running) {
        Write-Output "Found running AltTabby.exe from this directory - attempting to terminate..."
        try {
            $running | Stop-Process -Force -ErrorAction Stop
            Write-Output "  - Terminated AltTabby.exe"
            Start-Sleep -Seconds 2
        } catch {
            Write-Output "WARNING: Could not terminate AltTabby.exe"
            Write-Output "         Process may be running as Administrator."
            Write-Output "         Please close it manually and try again."
            Write-Output ""
            exit 1
        }
    } else {
        Write-Output "  - No running AltTabby.exe found in this directory"
    }
    Write-Output ""
    Record-Step "Process Check"
}

# --- Compile using v2 base interpreter ---
Reset-StepTimer
$compileError = 0

if ($exeNeeded) {
    $compileArgs = "/in `"$inputFile`" /out `"$outputFile`" /base `"$ahk2base`""
    if (Test-Path $iconFile) {
        $compileArgs += " /icon `"$iconFile`""
    }
    $compileArgs += " /silent verbose"

    $compileProc = Start-Process -FilePath $ahk2exe -ArgumentList $compileArgs -Wait -PassThru -WindowStyle Hidden
    $compileError = $compileProc.ExitCode
}
Record-Step $exeLabel

if ($compileError -ne 0) {
    # Cleanup temp dir on failure
    if ($profileTempDir -and (Test-Path $profileTempDir)) {
        Remove-Item $profileTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Check if the target exe is locked by a running process from THIS directory
    $blocking = Find-BlockingProcesses $releaseDir
    if ($blocking) {
        $pids = ($blocking | ForEach-Object { $_.Id }) -join ", "
        Write-Output ""
        Write-Output "ERROR: Target exe is locked - AltTabby.exe is running from this directory."
        Write-Output "       PID(s): $pids"
        Write-Output "       Path:   $outputFile"
        Write-Output ""
        Write-Output "Close the running instance and retry. Ahk2Exe cannot overwrite a locked file."
        Write-Output ""
        exit 1
    }

    Write-Output ""
    Write-Output "ERROR: Compilation failed with error code $compileError"
    Write-Output ""
    if (-not $testMode) {
        Write-Output "Try running Ahk2Exe.exe GUI and selecting:"
        Write-Output "  Source: $inputFile"
        Write-Output "  Base File: v2.0.19 U64 AutoHotkey64.exe"
        Write-Output ""
    }
    exit 1
}

# --- Verify output exists ---
Reset-StepTimer
if (-not (Test-Path $outputFile)) {
    # Cleanup temp dir on failure
    if ($profileTempDir -and (Test-Path $profileTempDir)) {
        Remove-Item $profileTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Output ""
    Write-Output "ERROR: Output file not created!"
    Write-Output "Expected: $outputFile"
    Write-Output ""
    if (-not $testMode) {
        Write-Output "The compilation may have failed silently. Try:"
        Write-Output "  1. Run Ahk2Exe.exe GUI manually"
        Write-Output "  2. Select Source: $inputFile"
        Write-Output "  3. Select Base File: v2.0.19 U64 AutoHotkey64.exe"
        Write-Output ""
    }
    exit 1
}
Record-Step "Verify"

# --- Cleanup temp directory ---
if ($profileTempDir -and (Test-Path $profileTempDir)) {
    Remove-Item $profileTempDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Success ---
if (-not $testMode) {
    Write-Output ""
    Write-Output "============================================================"
    Write-Output "SUCCESS - Compiled to: $outputFile"
    Write-Output "============================================================"
    Write-Output ""
    Write-Output "Usage:"
    Write-Output "  AltTabby.exe             - Launch GUI + Store"
    Write-Output "  AltTabby.exe --store     - Store server only"
    Write-Output "  AltTabby.exe --viewer    - Debug viewer only"
    Write-Output "  AltTabby.exe --gui-only  - GUI only (store must be running)"
    Write-Output ""
    Write-Output "TIP: Run as Administrator for full functionality"
    Write-Output "     (required to intercept Alt+Tab in admin windows)"
    Write-Output ""
}

exit 0
