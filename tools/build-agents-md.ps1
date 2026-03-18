# ============================================================
# Build AGENTS.MD
# ============================================================
# Consolidates CLAUDE.md + .claude/rules/*.md into a single
# AGENTS.MD for non-Claude AI agents.
# Usage: build-agents-md.ps1 [--force]
# ============================================================

param(
    [switch]$force
)

# Project root (script lives in tools/, project root is one level up)
$projectRoot = (Resolve-Path "$PSScriptRoot\..").Path

$outFile   = Join-Path $projectRoot "AGENTS.MD"
$claudeMd  = Join-Path $projectRoot "CLAUDE.md"
$rulesDir  = Join-Path $projectRoot ".claude\rules"
$scriptSelf = $PSCommandPath

# --- Collect source files ---
$sources = @($claudeMd, $scriptSelf)
$rulesFiles = @()
if (Test-Path $rulesDir) {
    $rulesFiles = Get-ChildItem -Path $rulesDir -Filter "*.md" | Sort-Object Name
    $sources += $rulesFiles | ForEach-Object { $_.FullName }
}

# --- Smart skip: rebuild only if any source is newer than output ---
if (-not $force -and (Test-Path $outFile)) {
    $outTime = (Get-Item $outFile).LastWriteTime
    $needsRebuild = $false
    foreach ($src in $sources) {
        if ((Get-Item $src).LastWriteTime -gt $outTime) {
            $needsRebuild = $true
            break
        }
    }
    if (-not $needsRebuild) {
        Write-Output "AGENTS.MD up to date - skipping generation"
        exit 0
    }
}

# --- Build content ---
$parts = @()

# CLAUDE.md content (strip "## Additional Context" section and everything after it)
$claudeContent = Get-Content $claudeMd -Raw
$claudeContent = $claudeContent -replace '(?ms)\r?\n---\r?\n\r?\n## Additional Context.*\z', ''
$parts += $claudeContent

# Rules files, each preceded by a separator
foreach ($rule in $rulesFiles) {
    $parts += "---`n`n" + (Get-Content $rule.FullName -Raw)
}

$content = $parts -join "`n"

# --- Replace "Claude" (agent name) with "the agent" ---
# Word-boundary match, case-sensitive. Won't touch .claude/ paths (lowercase).
$content = [regex]::Replace($content, '\bClaude\b', 'the agent')

# --- Prepend auto-generated header ---
$header = "<!-- Auto-generated from CLAUDE.md + .claude/rules/ -- do not edit manually -->`n`n"
$content = $header + $content

# --- Write output ---
[System.IO.File]::WriteAllText($outFile, $content)
$count = $sources.Count
Write-Output "Generated AGENTS.MD ($count source files)"
