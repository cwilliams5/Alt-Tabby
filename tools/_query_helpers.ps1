# _query_helpers.ps1 - Shared helpers for query tools
#
# Dot-sourced by query_*.ps1 to eliminate code duplication and apply
# micro-optimizations (pre-compiled regex, HashSet lookups) in one place.
#
# NOT a standalone tool. The _ prefix marks it as private to tools/.

# === AHK keyword/builtin sets (O(1) lookup via HashSet) ===
$script:AHK_KEYWORDS_SET = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'if', 'else', 'while', 'for', 'loop', 'switch', 'case', 'catch',
        'finally', 'try', 'class', 'return', 'throw', 'static', 'global',
        'local', 'until', 'not', 'and', 'or', 'is', 'in', 'contains',
        'new', 'super', 'this', 'true', 'false', 'unset', 'isset'
    ),
    [System.StringComparer]::OrdinalIgnoreCase)

$script:AHK_BUILTINS_SET = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('true', 'false', 'unset', 'this', 'super'),
    [System.StringComparer]::OrdinalIgnoreCase)

# === Pre-compiled regex for Clean-Line (JIT-compiled to IL for hot-path use) ===
$script:_rxDblQuote = [regex]::new('"[^"]*"', 'Compiled')
$script:_rxSglQuote = [regex]::new("'[^']*'", 'Compiled')
$script:_rxComment  = [regex]::new('\s;.*$', 'Compiled')
# Word-extraction regex (used by query_global_ownership Pass 2)
$script:_rxWord     = [regex]::new('\b[a-zA-Z_]\w+\b', 'Compiled')
# Function definition regex (used by Build-FuncBoundaryMap, shared by query_ipc/messages/timers)
# NOTE: No 'Compiled' flag — JIT overhead is not amortized in short-lived tool processes
$script:_rxFuncDef  = [regex]::new('^(\w+)\s*\(')

function Clean-Line {
    param([string]$line)
    $trimmed = $line.TrimStart()
    if ($trimmed.Length -eq 0 -or $trimmed[0] -eq ';') { return '' }
    if ($trimmed.IndexOf('"') -lt 0 -and $trimmed.IndexOf("'") -lt 0 -and $trimmed.IndexOf(';') -lt 0) {
        return $trimmed
    }
    $cleaned = $script:_rxDblQuote.Replace($trimmed, '""')
    $cleaned = $script:_rxSglQuote.Replace($cleaned, "''")
    $cleaned = $script:_rxComment.Replace($cleaned, '')
    return $cleaned
}

function Strip-Nested {
    param([string]$s)
    $result = [System.Text.StringBuilder]::new($s.Length)
    $depth = 0
    foreach ($c in $s.ToCharArray()) {
        if ($c -eq '(' -or $c -eq '[') { $depth++ }
        elseif ($c -eq ')' -or $c -eq ']') { if ($depth -gt 0) { $depth-- } }
        elseif ($depth -eq 0) { [void]$result.Append($c) }
    }
    return $result.ToString()
}

function Get-AhkSourceFiles {
    param([string]$SrcDir)
    $allPaths = [System.IO.Directory]::GetFiles($SrcDir, "*.ahk",
        [System.IO.SearchOption]::AllDirectories)
    $result = [System.Collections.ArrayList]::new($allPaths.Count)
    foreach ($p in $allPaths) {
        if ($p.IndexOf('\lib\') -lt 0) {
            [void]$result.Add([System.IO.FileInfo]::new($p))
        }
    }
    return ,$result
}

# Fast line-split: .Split() avoids regex overhead vs -split '\r?\n'
$script:_LINE_SEPS = [string[]]@("`r`n", "`n")

function Split-Lines {
    param([string]$Text)
    return $Text.Split($script:_LINE_SEPS, [StringSplitOptions]::None)
}

# Build function boundary map for a file (used by query_ipc, query_messages, query_timers)
function Build-FuncBoundaryMap {
    param([string[]]$Lines)
    $bounds = [System.Collections.ArrayList]::new()
    for ($j = 0; $j -lt $Lines.Count; $j++) {
        $m = $script:_rxFuncDef.Match($Lines[$j])
        if ($m.Success) {
            $candidate = $m.Groups[1].Value
            if ($script:AHK_KEYWORDS_SET.Contains($candidate)) { continue }
            $hasBody = $Lines[$j].Contains('{')
            if (-not $hasBody) {
                for ($k = $j + 1; $k -lt [Math]::Min($j + 3, $Lines.Count); $k++) {
                    $next = $Lines[$k].Trim()
                    if ($next -eq '') { continue }
                    if ($next -eq '{' -or $next.StartsWith('{')) { $hasBody = $true }
                    break
                }
            }
            if ($hasBody) { [void]$bounds.Add(@{ Name = $candidate; Line = $j }) }
        }
    }
    return $bounds
}

# Reverse lookup: find enclosing function for a line index
function Find-EnclosingFunction {
    param($Bounds, [int]$FromIndex)
    for ($b = $Bounds.Count - 1; $b -ge 0; $b--) {
        if ($Bounds[$b].Line -le $FromIndex) { return $Bounds[$b].Name }
    }
    return "(file scope)"
}
