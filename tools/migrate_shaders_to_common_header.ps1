# migrate_shaders_to_common_header.ps1 — One-time migration: strip boilerplate from all
# HLSL shaders, replacing with AT_PostProcess() calls from alt_tabby_common.hlsl.
#
# Usage: powershell -File tools/migrate_shaders_to_common_header.ps1 [-DryRun]

param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$shaderDir = Join-Path $repoRoot 'src\shaders'

$hlslFiles = @(Get-ChildItem -Path $shaderDir -Filter '*.hlsl' |
    Where-Object { $_.Name -ne 'alt_tabby_common.hlsl' } | Sort-Object Name)

Write-Host "Found $($hlslFiles.Count) shader files to migrate."

# Custom-alpha shaders: filename -> alpha expression to use with AT_PostProcess(col, alpha)
$customAlphaShaders = @{
    '70s_melt.hlsl'      = 'saturate(extrusion)'
    'base_warp_fbm.hlsl' = 'saturate(shade)'
    'bokeh_gradient.hlsl' = 'totalAlpha'
    'raindrops_glass.hlsl' = 'dropMask'
}

# domain_warped_fbm_noise.hlsl is a hybrid — handled separately
$hybridShaders = @('domain_warped_fbm_noise.hlsl')

$processed = 0
$failures = @()

foreach ($file in $hlslFiles) {
    $content = [IO.File]::ReadAllText($file.FullName)
    $original = $content
    $fileName = $file.Name
    $isCustomAlpha = $customAlphaShaders.ContainsKey($fileName)
    $isHybrid = $hybridShaders -contains $fileName

    # --- Step 1: Strip cbuffer block ---
    # Match: cbuffer Constants : register(b0) { ... };
    $cbufferPattern = '(?m)^cbuffer Constants\s*:\s*register\(b0\)\s*\{[^}]*\};\s*\r?\n'
    if ($content -match $cbufferPattern) {
        $content = $content -replace $cbufferPattern, ''
    } else {
        $failures += "$fileName : cbuffer not found"
        continue
    }

    # --- Step 2: Strip PSInput struct ---
    $psInputPattern = '(?m)^struct PSInput\s*\{[^}]*\};\s*\r?\n'
    if ($content -match $psInputPattern) {
        $content = $content -replace $psInputPattern, ''
    } else {
        $failures += "$fileName : PSInput not found"
        continue
    }

    # --- Step 3: Replace post-processing tail ---
    if ($isHybrid) {
        # domain_warped_fbm_noise.hlsl: hybrid pattern — keep manual post-processing
        # but inject opacity into the return. Strip darken/desat + return block and replace.
        $hybridPattern = '(?ms)    // Darken/desaturate post-processing\r?\n' +
            '    float lum = dot\((\w+), float3\(0\.299, 0\.587, 0\.114\)\);\r?\n' +
            '    \1 = lerp\(\1, \(float3\)lum, desaturate\);\r?\n' +
            '    \1 = \1 \* \(1\.0 - darken\);\r?\n' +
            '\r?\n' +
            '    // Alpha from brightness, premultiplied\r?\n' +
            '    float a = saturate\(alphaOrig\) \* max\(\1\.r, max\(\1\.g, \1\.b\)\);\r?\n' +
            '    return float4\(\1 \* saturate\(alphaOrig\), a\);\r?\n'
        if ($content -match '(?ms)    // Darken/desaturate post-processing\r?\n    float lum = dot\((\w+),') {
            $varName = $Matches[1]
            # Replace with AT_PostProcess-based code. The hybrid nature:
            # RGB premultiplied by saturate(alphaOrig), alpha = saturate(alphaOrig) * maxBrightness
            # This is equivalent to: let AT_PostProcess handle darken/desat/opacity on col,
            # then apply custom alpha multiply. But AT_PostProcess returns premultiplied output.
            # Safest: use a manual but opacity-aware replacement.
            $replacement = "    // Post-process via shared AT_PostProcess (hybrid alpha: alphaOrig * brightness)`n" +
                "    float customA = saturate(alphaOrig);`n" +
                "    float4 pp = AT_PostProcess($varName);`n" +
                "    return float4(pp.rgb * (customA / max(pp.a, 0.001)), pp.a * customA);`n"
            # Actually this gets complex. Let's just use inline with opacity.
            $replacement = "    // Darken/desaturate + hybrid alpha (brightness * alphaOrig)`n" +
                "    float lum = dot($varName, float3(0.299, 0.587, 0.114));`n" +
                "    $varName = lerp($varName, (float3)lum, desaturate);`n" +
                "    $varName = $varName * (1.0 - darken);`n" +
                "`n" +
                "    float a = saturate(alphaOrig) * max($varName.r, max($varName.g, $varName.b)) * opacity;`n" +
                "    return float4($varName * saturate(alphaOrig) * opacity, a);`n"

            # Do a simpler replacement: find the block and replace
            $blockPattern = '(?m)(    // Darken/desaturate post-processing\r?\n)(    float lum = dot\(' + $varName + ', float3\(0\.299, 0\.587, 0\.114\)\);\r?\n)(    ' + $varName + ' = lerp\(' + $varName + ', \(float3\)lum, desaturate\);\r?\n)(    ' + $varName + ' = ' + $varName + ' \* \(1\.0 - darken\);\r?\n)(\r?\n)(    // Alpha from brightness, premultiplied\r?\n)(    float a = saturate\(alphaOrig\) \* max\(' + $varName + '\.r, max\(' + $varName + '\.g, ' + $varName + '\.b\)\);\r?\n)(    return float4\(' + $varName + ' \* saturate\(alphaOrig\), a\);\r?\n)'
            $content = $content -replace $blockPattern, $replacement
        } else {
            $failures += "$fileName : hybrid post-processing pattern not matched"
            continue
        }
    } elseif ($isCustomAlpha) {
        $alphaExpr = $customAlphaShaders[$fileName]

        # Custom alpha shaders: find the darken/desat block + custom return, replace with AT_PostProcess(col, alpha)
        # Pattern varies per shader — find the lum line to get the variable name, then match through return
        if ($content -match '(?m)    float lum = dot\((\w+), float3\(0\.299, 0\.587, 0\.114\)\);') {
            $varName = $Matches[1]
        } elseif ($content -match '(?m)  float lum = dot\((\w+), float3\(0\.299, 0\.587, 0\.114\)\);') {
            $varName = $Matches[1]
        } else {
            $failures += "$fileName : custom alpha - lum variable not found"
            continue
        }

        # For custom alpha shaders, the pattern is:
        # [comment line(s)]
        # float lum = dot(VAR, ...);
        # VAR = lerp(VAR, (float3)lum, desaturate);
        # VAR = VAR * (1.0 - darken);
        # [blank line]
        # [comment line(s)]
        # float a = ALPHA_EXPR;
        # return float4(VAR * a, a);
        #
        # Or variations like:
        # return float4(VAR * ALPHA_EXPR, ALPHA_EXPR);  (bokeh_gradient: totalAlpha)
        # return float4(FinalColor * alpha, alpha);  (raindrops_glass)

        # Generic approach: match from the comment before lum to the return line
        # Use a broad pattern that captures comment + lum + desat + darken + blank + comment + alpha + return
        $commentAndBlock = '(?ms)([ \t]*//[^\n]*\r?\n)*[ \t]*float lum = dot\(' + [regex]::Escape($varName) + ', float3\(0\.299, 0\.587, 0\.114\)\);.*?return float4\([^)]+\);\r?\n'

        if ($content -match $commentAndBlock) {
            $matchText = $Matches[0]
            $indent = '    '
            $replacement = "${indent}return AT_PostProcess($varName, $alphaExpr);`n"
            $content = $content.Replace($matchText, $replacement)
        } else {
            $failures += "$fileName : custom alpha block pattern not matched"
            continue
        }
    } else {
        # Standard shader: match the darken/desat block + brightness alpha + return
        # Find the variable name from the lum line
        if ($content -match '(?m)([ \t]*)float lum = dot\((\w+), float3\(0\.299, 0\.587, 0\.114\)\);') {
            $indent = $Matches[1]
            $varName = $Matches[2]
        } else {
            $failures += "$fileName : lum variable not found"
            continue
        }

        # Match the entire post-processing block: from the comment line (or lum line) through the return
        # The block typically looks like:
        # [optional comment]
        # float lum = dot(VAR, float3(0.299, 0.587, 0.114));
        # VAR = lerp(VAR, (float3)lum, desaturate);
        # VAR = VAR * (1.0 - darken);   OR   VAR *= 1.0 - darken;
        # [blank line]
        # [optional comment]
        # float a/alpha/al/a_val/a_out/outA = max(VAR.r, max(VAR.g, VAR.b));
        # return float4(VAR * a, a);
        $commentAndBlock = '(?ms)([ \t]*//[^\n]*\r?\n)*[ \t]*float lum = dot\(' + [regex]::Escape($varName) + ', float3\(0\.299, 0\.587, 0\.114\)\);.*?return float4\([^)]+\);\r?\n'

        if ($content -match $commentAndBlock) {
            $matchText = $Matches[0]
            $replacement = "${indent}return AT_PostProcess($varName);`n"
            $content = $content.Replace($matchText, $replacement)
        } else {
            $failures += "$fileName : standard block pattern not matched"
            continue
        }
    }

    # --- Step 4: Clean up blank lines (normalize multiple to at most one) ---
    while ($content -match '\r?\n\r?\n\r?\n') {
        $content = $content -replace '(\r?\n)\r?\n(\r?\n)', '$1$2'
    }

    # Remove leading blank lines
    $content = $content -replace '^\s*\r?\n', ''

    # --- Step 5: Validate ---
    if ($content -notmatch 'PSMain') {
        $failures += "$fileName : PSMain not found after migration"
        continue
    }
    if ($content -notmatch 'AT_PostProcess|opacity') {
        $failures += "$fileName : AT_PostProcess/opacity not found after migration"
        continue
    }
    # Verify no leftover cbuffer or PSInput
    if ($content -match 'cbuffer Constants') {
        $failures += "$fileName : leftover cbuffer after migration"
        continue
    }
    if ($content -match 'struct PSInput') {
        $failures += "$fileName : leftover PSInput after migration"
        continue
    }

    if ($DryRun) {
        Write-Host "  DRY-RUN: $fileName OK"
    } else {
        # Write back with UTF-8 no BOM
        [IO.File]::WriteAllText($file.FullName, $content, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  OK: $fileName"
    }
    $processed++
}

Write-Host ""
Write-Host "Processed: $processed / $($hlslFiles.Count)"
if ($failures.Count -gt 0) {
    Write-Host "Failures ($($failures.Count)):" -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "  $f" -ForegroundColor Red
    }
    exit 1
}
Write-Host "All $processed shaders migrated successfully."
exit 0
