# check_skill_frontmatter.ps1 - Enforce skill frontmatter policy
#
# Every SKILL.md must have:
#   - name (required)
#   - description (required)
#   - user-invocable: true (required, explicit)
#   - disable-model-invocation: true (default) or false (whitelisted only)
#
# Skills with disable-model-invocation: false have their description loaded
# into context every session. The whitelist keeps this list intentionally small.
#
# Failure modes:
#   [auto-fix]  - Agent can add the missing field automatically
#   [STOP]      - Agent must confirm with user before proceeding
#
# Usage: powershell -File tests\check_skill_frontmatter.ps1
# Exit codes: 0 = all pass, 1 = any failure

param(
    [string]$SkillsDir
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# === Whitelist: skills allowed to have disable-model-invocation: false ===
# These skills stay in context so Claude can auto-invoke them.
# Adding to this list requires user confirmation.
$AutoDiscoverWhitelist = @(
    "explain"
    "investigate"
)

# === Resolve skills directory ===
if (-not $SkillsDir) {
    $SkillsDir = (Resolve-Path "$PSScriptRoot\..\.claude\skills").Path
}
if (-not (Test-Path $SkillsDir)) {
    Write-Host "  ERROR: Skills directory not found: $SkillsDir" -ForegroundColor Red
    exit 1
}

# === Parse YAML frontmatter ===
function Get-SkillFrontmatter {
    param([string]$FilePath)

    $lines = [System.IO.File]::ReadAllLines($FilePath)
    $fm = @{}
    $inFrontmatter = $false
    $dashCount = 0

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '---') {
            $dashCount++
            if ($dashCount -eq 1) { $inFrontmatter = $true; continue }
            if ($dashCount -eq 2) { break }
        }
        if ($inFrontmatter -and $trimmed -and $trimmed -match '^([^:]+):\s*(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim().Trim('"', "'")
            $fm[$key] = $value
        }
    }
    return $fm
}

# === Check all skills ===
$failures = [System.Collections.ArrayList]::new()
$skillCount = 0

$skillDirs = Get-ChildItem -Path $SkillsDir -Directory | Sort-Object Name
foreach ($dir in $skillDirs) {
    $skillFile = Join-Path $dir.FullName "SKILL.md"
    if (-not (Test-Path $skillFile)) { continue }

    $skillName = $dir.Name
    $skillCount++
    $fm = Get-SkillFrontmatter -FilePath $skillFile

    # --- Check: name ---
    if (-not $fm.ContainsKey('name') -or -not $fm['name']) {
        [void]$failures.Add("[auto-fix] $skillName : Missing 'name'. Add 'name: $skillName' to frontmatter.")
    }

    # --- Check: description ---
    if (-not $fm.ContainsKey('description') -or -not $fm['description']) {
        [void]$failures.Add("[auto-fix] $skillName : Missing 'description'. Every skill needs a description.")
    }

    # --- Check: user-invocable (must be explicit true) ---
    # Accept both hyphen and underscore variants
    $userInvocable = $null
    if ($fm.ContainsKey('user-invocable')) { $userInvocable = $fm['user-invocable'] }
    elseif ($fm.ContainsKey('user_invocable')) { $userInvocable = $fm['user_invocable'] }

    if ($null -eq $userInvocable) {
        [void]$failures.Add("[auto-fix] $skillName : Missing 'user-invocable'. Add 'user-invocable: true'.")
    } elseif ($userInvocable -ne 'true') {
        [void]$failures.Add("[auto-fix] $skillName : 'user-invocable' must be 'true', got '$userInvocable'.")
    }

    # --- Check: disable-model-invocation (must be explicit) ---
    # Accept both hyphen and underscore variants
    $disableModel = $null
    if ($fm.ContainsKey('disable-model-invocation')) { $disableModel = $fm['disable-model-invocation'] }
    elseif ($fm.ContainsKey('disable_model_invocation')) { $disableModel = $fm['disable_model_invocation'] }

    if ($null -eq $disableModel) {
        # Missing entirely
        if ($skillName -in $AutoDiscoverWhitelist) {
            [void]$failures.Add("[auto-fix] $skillName : Missing 'disable-model-invocation'. Add 'disable-model-invocation: false' (whitelisted).")
        } else {
            [void]$failures.Add("[auto-fix] $skillName : Missing 'disable-model-invocation'. Add 'disable-model-invocation: true'.")
        }
    } elseif ($disableModel -eq 'false') {
        # Explicitly false — must be whitelisted
        if ($skillName -notin $AutoDiscoverWhitelist) {
            [void]$failures.Add("[STOP] $skillName : 'disable-model-invocation: false' but NOT in whitelist. Confirm with user before adding to whitelist.")
        }
    } elseif ($disableModel -eq 'true') {
        # Explicitly true — always OK
    } else {
        [void]$failures.Add("[auto-fix] $skillName : 'disable-model-invocation' must be 'true' or 'false', got '$disableModel'.")
    }

    # --- Check: underscore keys (legacy format) ---
    if ($fm.ContainsKey('user_invocable')) {
        [void]$failures.Add("[auto-fix] $skillName : Uses 'user_invocable' (underscore). Rename to 'user-invocable' (hyphen).")
    }
    if ($fm.ContainsKey('disable_model_invocation')) {
        [void]$failures.Add("[auto-fix] $skillName : Uses 'disable_model_invocation' (underscore). Rename to 'disable-model-invocation' (hyphen).")
    }
}

# === Report ===
$sw.Stop()

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $($failures.Count) frontmatter issue(s) across $skillCount skills." -ForegroundColor Red
    Write-Host ""
    foreach ($f in $failures) {
        if ($f.StartsWith("[STOP]")) {
            Write-Host "    $f" -ForegroundColor Magenta
        } else {
            Write-Host "    $f" -ForegroundColor Red
        }
    }
    Write-Host ""
    Write-Host "  [auto-fix] issues can be corrected by a coding agent." -ForegroundColor Yellow
    Write-Host "  [STOP] issues require user confirmation before proceeding." -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Timing: $($sw.ElapsedMilliseconds)ms ($skillCount skills checked)" -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "  Skill frontmatter: all $skillCount skills valid [PASS]" -ForegroundColor Green
    Write-Host "  Auto-discoverable (whitelisted): $($AutoDiscoverWhitelist -join ', ')" -ForegroundColor Cyan
    Write-Host "  Timing: $($sw.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    exit 0
}
