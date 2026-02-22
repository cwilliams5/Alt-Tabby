# query_state.ps1 - State machine branch extractor
#
# Extracts specific event handler branches from GUI_OnInterceptorEvent
# without loading the full 234-line function.
#
# Usage:
#   powershell -File tools/query_state.ps1                       (list states and events)
#   powershell -File tools/query_state.ps1 ACTIVE                (all handlers for state)
#   powershell -File tools/query_state.ps1 ACTIVE TAB_STEP       (specific branch)

param(
    [Parameter(Position=0)]
    [string]$State,
    [Parameter(Position=1)]
    [string]$Event
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$projectRoot = Split-Path $PSScriptRoot -Parent
$guiStateFile = Join-Path $projectRoot "src\gui\gui_state.ahk"

if (-not (Test-Path $guiStateFile)) {
    Write-Host "  ERROR: Cannot find $guiStateFile" -ForegroundColor Red
    exit 1
}

$lines = [System.IO.File]::ReadAllLines($guiStateFile)
$relPath = "src\gui\gui_state.ahk"

# === Find GUI_OnInterceptorEvent function boundaries ===
$funcStart = -1
$funcEnd = -1
$funcDepth = 0

for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($funcStart -eq -1) {
        if ($lines[$i] -match '^GUI_OnInterceptorEvent\s*\(') {
            $funcStart = $i
            # Count braces on this line
            foreach ($c in $lines[$i].ToCharArray()) {
                if ($c -eq '{') { $funcDepth++ }
                elseif ($c -eq '}') { $funcDepth-- }
            }
        }
        continue
    }

    # Inside function - track brace depth
    # Strip strings and comments for accurate counting
    $cleaned = $lines[$i] -replace '"[^"]*"', '""'
    $cleaned = $cleaned -replace "'[^']*'", "''"
    $cleaned = $cleaned -replace '\s;.*$', ''
    if ($cleaned -match '^\s*;') { $cleaned = '' }

    foreach ($c in $cleaned.ToCharArray()) {
        if ($c -eq '{') { $funcDepth++ }
        elseif ($c -eq '}') { $funcDepth-- }
    }

    if ($funcDepth -le 0) {
        $funcEnd = $i
        break
    }
}

if ($funcStart -eq -1) {
    Write-Host "  ERROR: GUI_OnInterceptorEvent not found in $relPath" -ForegroundColor Red
    exit 1
}
if ($funcEnd -eq -1) { $funcEnd = $lines.Count - 1 }

# === Parse event branches ===
# The function uses top-level `if (evCode = TABBY_EV_*)` blocks.
# Inside those, `if (gGUI_State = "STATE")` blocks handle per-state logic.

# Event name mapping: constant -> display name
$eventNames = @{
    'TABBY_EV_ALT_DOWN' = 'ALT_DOWN'
    'TABBY_EV_TAB_STEP' = 'TAB_STEP'
    'TABBY_EV_ALT_UP'   = 'ALT_UP'
    'TABBY_EV_ESCAPE'   = 'ESCAPE'
}

# Parse structure: find event blocks and state sub-blocks within them
$branches = [System.Collections.ArrayList]::new()

for ($i = $funcStart + 1; $i -lt $funcEnd; $i++) {
    $trimmed = $lines[$i].Trim()

    # Top-level event check: if (evCode = TABBY_EV_*)
    if ($trimmed -match '^\s*if\s*\(\s*evCode\s*=\s*(TABBY_EV_\w+)\s*\)') {
        $evConst = $Matches[1]
        $evName = if ($eventNames.ContainsKey($evConst)) { $eventNames[$evConst] } else { $evConst }
        $evBlockStart = $i

        # Find the end of this event block by tracking brace depth
        $evDepth = 0
        $evBlockEnd = $i
        for ($j = $i; $j -le $funcEnd; $j++) {
            $cl = $lines[$j] -replace '"[^"]*"', '""'
            $cl = $cl -replace "'[^']*'", "''"
            $cl = $cl -replace '\s;.*$', ''
            if ($cl -match '^\s*;') { $cl = '' }
            foreach ($c in $cl.ToCharArray()) {
                if ($c -eq '{') { $evDepth++ }
                elseif ($c -eq '}') { $evDepth-- }
            }
            if ($evDepth -le 0 -and $j -gt $i) {
                $evBlockEnd = $j
                break
            }
        }

        # Now find state sub-blocks within this event block
        $statesFound = [System.Collections.ArrayList]::new()

        for ($k = $evBlockStart + 1; $k -lt $evBlockEnd; $k++) {
            $stTrimmed = $lines[$k].Trim()

            # State check: if (gGUI_State = "STATE")
            if ($stTrimmed -match 'gGUI_State\s*=\s*"(\w+)"') {
                $stateName = $Matches[1]
                $stBlockStart = $k

                # Find end of this state block
                $stDepth = 0
                $stBlockEnd = $k
                for ($m = $k; $m -lt $evBlockEnd; $m++) {
                    $scl = $lines[$m] -replace '"[^"]*"', '""'
                    $scl = $scl -replace "'[^']*'", "''"
                    $scl = $scl -replace '\s;.*$', ''
                    if ($scl -match '^\s*;') { $scl = '' }
                    foreach ($c in $scl.ToCharArray()) {
                        if ($c -eq '{') { $stDepth++ }
                        elseif ($c -eq '}') { $stDepth-- }
                    }
                    if ($stDepth -le 0 -and $m -gt $k) {
                        $stBlockEnd = $m
                        break
                    }
                }

                [void]$statesFound.Add(@{
                    State     = $stateName
                    StartLine = $stBlockStart
                    EndLine   = $stBlockEnd
                })
            }
        }

        # If no state sub-blocks found, the entire event block is one branch
        if ($statesFound.Count -eq 0) {
            [void]$branches.Add(@{
                Event     = $evName
                State     = "(all)"
                StartLine = $evBlockStart
                EndLine   = $evBlockEnd
                Lines     = $evBlockEnd - $evBlockStart + 1
            })
        } else {
            # Add the event-level preamble (before first state check) as a branch too
            $firstStateStart = $statesFound[0].StartLine
            if ($firstStateStart -gt $evBlockStart + 1) {
                [void]$branches.Add(@{
                    Event     = $evName
                    State     = "(preamble)"
                    StartLine = $evBlockStart
                    EndLine   = $firstStateStart - 1
                    Lines     = $firstStateStart - $evBlockStart
                })
            }
            foreach ($st in $statesFound) {
                [void]$branches.Add(@{
                    Event     = $evName
                    State     = $st.State
                    StartLine = $st.StartLine
                    EndLine   = $st.EndLine
                    Lines     = $st.EndLine - $st.StartLine + 1
                })
            }
        }

        # Skip past the event block
        $i = $evBlockEnd
    }
}

# Also capture the preamble before the first event check (async buffering, logging)
$firstEventLine = $funcEnd
foreach ($b in $branches) {
    if ($b.StartLine -lt $firstEventLine) { $firstEventLine = $b.StartLine }
}
if ($firstEventLine -gt $funcStart + 1) {
    $preamble = @{
        Event     = "(preamble)"
        State     = "(all)"
        StartLine = $funcStart
        EndLine   = $firstEventLine - 1
        Lines     = $firstEventLine - $funcStart
    }
}

# === No-arg mode: show index ===
if (-not $State -and -not $Event) {
    Write-Host ""
    Write-Host "  GUI_OnInterceptorEvent - State Machine Index" -ForegroundColor White
    $funcLineCount = $funcEnd - $funcStart + 1
    $funcLoc = "${relPath}:$($funcStart + 1)-$($funcEnd + 1)"
    $funcInfo = '    {0} ({1} lines)' -f $funcLoc, $funcLineCount
    Write-Host $funcInfo -ForegroundColor DarkGray
    Write-Host ""

    # Show preamble
    if ($preamble) {
        $pStart = $preamble.StartLine + 1
        $pEnd = $preamble.EndLine + 1
        $pInfo = '    (preamble)  async buffering, logging    :{0}-{1} ({2} lines)' -f $pStart, $pEnd, $preamble.Lines
        Write-Host $pInfo -ForegroundColor DarkGray
    }

    # Group by event
    $events = $branches | Group-Object { $_.Event }
    foreach ($evGroup in $events) {
        Write-Host ""
        $evLabel = $evGroup.Name
        Write-Host "    ${evLabel}:" -ForegroundColor Cyan
        foreach ($b in $evGroup.Group) {
            $bStart = $b.StartLine + 1
            $bEnd = $b.EndLine + 1
            $stateLabel = $b.State.PadRight(14)
            $bInfo = '      {0} :{1}-{2} ({3} lines)' -f $stateLabel, $bStart, $bEnd, $b.Lines
            Write-Host $bInfo -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host '  Query: query_state.ps1 <state>             (all handlers for state)' -ForegroundColor DarkGray
    Write-Host '         query_state.ps1 <state> <event>      (specific branch)' -ForegroundColor DarkGray
    $elapsed = $sw.ElapsedMilliseconds
    Write-Host "  Completed in ${elapsed}ms" -ForegroundColor DarkGray
    exit 0
}

# === Normalize inputs ===
$stateUpper = $State.ToUpper()
$eventUpper = if ($Event) { $Event.ToUpper() } else { "" }

# Normalize: strip TABBY_EV_ prefix if provided
$eventUpper = $eventUpper -replace '^TABBY_EV_', ''

# === Filter branches ===
$matched = [System.Collections.ArrayList]::new()

# Include preamble if querying all states or specific match
if ($preamble -and -not $eventUpper) {
    # Only include preamble in state queries if state is "(all)" or "(preamble)"
}

foreach ($b in $branches) {
    $stateMatch = ($b.State.ToUpper() -eq $stateUpper -or $b.State -eq "(all)" -or $b.State -eq "(preamble)")
    $eventMatch = (-not $eventUpper -or $b.Event.ToUpper() -eq $eventUpper)

    if ($eventUpper -and $stateUpper) {
        # Two args: exact state+event match
        if ($b.State.ToUpper() -eq $stateUpper -and $b.Event.ToUpper() -eq $eventUpper) {
            [void]$matched.Add($b)
        }
    } elseif ($stateUpper) {
        # One arg: show all branches for this state
        if ($b.State.ToUpper() -eq $stateUpper) {
            [void]$matched.Add($b)
        }
    }
}

if ($matched.Count -eq 0) {
    $query = if ($eventUpper) { "$stateUpper $eventUpper" } else { $stateUpper }
    Write-Host "`n  No branches matching: '$query'" -ForegroundColor Red
    Write-Host "  Available states: IDLE, ALT_PENDING, ACTIVE" -ForegroundColor DarkGray
    Write-Host "  Available events: ALT_DOWN, TAB_STEP, ALT_UP, ESCAPE" -ForegroundColor DarkGray
    $elapsed = $sw.ElapsedMilliseconds
    Write-Host "  Completed in ${elapsed}ms" -ForegroundColor DarkGray
    exit 1
}

# === Output matched branches ===
Write-Host ""
$query = if ($eventUpper) { "$stateUpper + $eventUpper" } else { "state=$stateUpper" }
Write-Host "  GUI_OnInterceptorEvent - $query" -ForegroundColor White
Write-Host ""

foreach ($b in $matched) {
    $startLineNum = $b.StartLine + 1
    $endLineNum = $b.EndLine + 1
    $bLoc = "${relPath}:${startLineNum}-${endLineNum}"
    $branchHeader = '  {0} / {1}  {2} ({3} lines)' -f $b.Event, $b.State, $bLoc, $b.Lines
    Write-Host $branchHeader -ForegroundColor Cyan
    Write-Host "  $('-' * 60)" -ForegroundColor DarkGray

    for ($i = $b.StartLine; $i -le $b.EndLine; $i++) {
        $lineNum = $i + 1
        $prefix = "  {0,4}  " -f $lineNum
        Write-Host "$prefix$($lines[$i])" -ForegroundColor DarkGray
    }
    Write-Host ""
}

$elapsed = $sw.ElapsedMilliseconds
Write-Host "  Completed in ${elapsed}ms" -ForegroundColor DarkGray
