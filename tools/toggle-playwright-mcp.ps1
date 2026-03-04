# toggle-playwright-mcp.ps1 - Add or remove the Playwright MCP server from Claude Code config
# Usage: powershell -File tools\toggle-playwright-mcp.ps1 [on|off|status]
# Requires Claude Code restart to take effect.

param(
    [Parameter(Position=0)]
    [ValidateSet("on", "off", "status")]
    [string]$Action = "status"
)

$configPath = Join-Path $env:USERPROFILE ".claude.json"

if (-not (Test-Path $configPath)) {
    Write-Error "Claude config not found at $configPath"
    exit 1
}

$json = Get-Content $configPath -Raw | ConvertFrom-Json

# Ensure mcpServers exists
if (-not $json.PSObject.Properties['mcpServers']) {
    $json | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue ([PSCustomObject]@{})
}

$hasPW = $json.mcpServers.PSObject.Properties['playwright'] -ne $null

if ($Action -eq "status") {
    if ($hasPW) {
        Write-Host "Playwright MCP: ON"
    } else {
        Write-Host "Playwright MCP: OFF"
    }
}
elseif ($Action -eq "on") {
    if ($hasPW) {
        Write-Host "Playwright MCP already enabled"
    } else {
        $pw = [PSCustomObject]@{
            type    = "stdio"
            command = "cmd"
            args    = @("/c", "npx", "@playwright/mcp@latest")
            env     = [PSCustomObject]@{}
        }
        $json.mcpServers | Add-Member -NotePropertyName 'playwright' -NotePropertyValue $pw
        $json | ConvertTo-Json -Depth 20 | Set-Content $configPath -Encoding UTF8
        Write-Host "Playwright MCP: ENABLED - restart Claude Code to activate"
    }
}
elseif ($Action -eq "off") {
    if (-not $hasPW) {
        Write-Host "Playwright MCP already disabled"
    } else {
        $json.mcpServers.PSObject.Properties.Remove('playwright')
        $out = $json | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($configPath, $out)
        Write-Host "Playwright MCP: DISABLED - restart Claude Code to take effect"
    }
}
