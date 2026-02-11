# check_code_patterns.ps1 - Static analysis for production code patterns
# Pre-gate test: runs before any AHK process launches.
# Replaces FileRead+InStr code-inspection tests from AHK unit tests.
# Table-driven: each entry specifies a file, patterns to find, and a description.
#
# Usage: powershell -File tests\check_code_patterns.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all pass, 1 = any check failed

param(
    [string]$SourceDir,
    [switch]$BatchMode
)

$ErrorActionPreference = 'Stop'
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

# === Resolve source directory ===

if (-not $SourceDir) {
    $SourceDir = (Resolve-Path "$PSScriptRoot\..\src").Path
}
if (-not (Test-Path $SourceDir)) {
    Write-Host "  ERROR: Source directory not found: $SourceDir" -ForegroundColor Red
    if ($BatchMode) { return 1 } else { exit 1 }
}

# === Helpers ===

# File content cache (each file read once)
$script:FileCache = @{}

function Get-CachedContent {
    param([string]$RelPath)
    if (-not $script:FileCache.ContainsKey($RelPath)) {
        $fullPath = Join-Path $SourceDir $RelPath
        if (Test-Path $fullPath) {
            $script:FileCache[$RelPath] = [System.IO.File]::ReadAllText($fullPath)
        } else {
            $script:FileCache[$RelPath] = $null
        }
    }
    return $script:FileCache[$RelPath]
}

function Extract-FunctionBody {
    param([string]$Code, [string]$FuncName)

    # Match function DEFINITION, not call sites.
    # Definitions always end with ") {" on the same line.
    # Call sites lack the opening brace, so the pattern skips them.
    $escaped = [regex]::Escape($FuncName)
    $m = [regex]::Match($Code, "(?m)^[ \t]*(?:static\s+)?$escaped\([^)]*\)\s*\{")
    if (-not $m.Success) { return $null }
    $idx = $m.Index

    $braceIdx = $Code.IndexOf('{', $idx)
    if ($braceIdx -lt 0) { return $null }

    $depth = 1
    $i = $braceIdx + 1
    while ($i -lt $Code.Length -and $depth -gt 0) {
        $ch = $Code[$i]
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') { $depth-- }
        $i++
    }

    if ($depth -ne 0) { return $null }
    return $Code.Substring($braceIdx + 1, $i - $braceIdx - 2)
}

# === Check Table ===
# Each entry:
#   Id       - unique identifier
#   File     - relative path from src/
#   Desc     - human-readable description
#   Patterns - array of literal strings that must ALL be present (unless AnyOf/NotPresent)
#   Function - (optional) extract this function body before matching
#   Regex    - (optional) $true = use -match instead of .Contains()
#   AnyOf    - (optional) array where at least ONE must match
#   NotPresent - (optional) array of patterns that must NOT appear
#   MinCount - (optional) count occurrences of Patterns[0] and require >= MinCount

$CHECKS = @(
    # --- GDI+ Shutdown (from test_unit_cleanup.ahk) ---
    @{
        Id       = "gdip_shutdown_exists"
        File     = "gui\gui_gdip.ahk"
        Desc     = "Gdip_Shutdown() exists with cleanup calls"
        Patterns = @("Gdip_Shutdown()", "GdiplusShutdown", "GdipDeleteGraphics")
    },
    @{
        Id       = "gdip_shutdown_clears_globals"
        File     = "gui\gui_gdip.ahk"
        Desc     = "Gdip_Shutdown() clears all GDI+ globals"
        Patterns = @("gGdip_Token := 0", "gGdip_G := 0", "gGdip_BackHdc := 0", "gGdip_BackHBM := 0")
    },
    @{
        Id       = "gdip_shutdown_dispose"
        File     = "gui\gui_gdip.ahk"
        Desc     = "Gdip_Shutdown() calls _Gdip_DisposeResources()"
        Patterns = @("_Gdip_DisposeResources()")
    },

    # --- OnExit Handler Registration (from test_unit_cleanup.ahk) ---
    @{
        Id       = "viewer_onexit"
        File     = "viewer\viewer.ahk"
        Desc     = "Viewer has _Viewer_OnExitWrapper and registers OnExit"
        Patterns = @("_Viewer_OnExitWrapper", "OnExit(_Viewer_OnExitWrapper)")
    },
    @{
        Id       = "gui_onexit"
        File     = "gui\gui_main.ahk"
        Desc     = "GUI has _GUI_OnExit and registers OnExit"
        Patterns = @("_GUI_OnExit", "OnExit(_GUI_OnExit)")
    },
    @{
        Id       = "gui_onerror_handler"
        File     = "gui\gui_main.ahk"
        Desc     = "GUI has OnError handler registered"
        Patterns = @("OnError(")
    },
    @{
        Id       = "store_onexit_icons"
        File     = "store\store_server.ahk"
        Desc     = "_Store_OnExit calls both icon cleanup functions"
        Function = "_Store_OnExit"
        Patterns = @("WindowStore_CleanupAllIcons()", "WindowStore_CleanupExeIconCache()")
    },
    @{
        Id       = "gui_onexit_gdip"
        File     = "gui\gui_main.ahk"
        Desc     = "GUI _GUI_OnExit calls Gdip_Shutdown()"
        Function = "_GUI_OnExit"
        Patterns = @("Gdip_Shutdown()")
    },

    # --- Function Reference Validation (from test_unit_cleanup.ahk) ---
    @{
        Id       = "ksub_no_undefined_log"
        File     = "store\komorebi_sub.ahk"
        Desc     = "No undefined _KSub_Log() calls (should be KSub_DiagLog)"
        NotPresent = @("_KSub_Log(")
    },

    # --- Client Disconnect Cleanup (from test_unit_cleanup.ahk) ---
    @{
        Id       = "ipc_ondisconnect_support"
        File     = "shared\ipc_pipe.ahk"
        Desc     = "IPC server has onDisconnect callback support"
        Patterns = @("onDisconnectFn", "onDisconnect:", "server.onDisconnect")
    },
    @{
        Id       = "store_disconnect_cleanup"
        File     = "store\store_server.ahk"
        Desc     = "Store registers disconnect callback and cleans all client state"
        Patterns = @(
            "_Store_OnClientDisconnect)",
            "_Store_OnClientDisconnect(hPipe)",
            "gStore_ClientState.Delete("
        )
    },

    # --- Buffer Overflow Protection (from test_unit_cleanup.ahk) ---
    @{
        Id       = "ksub_buffer_overflow"
        File     = "store\komorebi_sub.ahk"
        Desc     = "Komorebi subscription has 1MB buffer overflow protection"
        Patterns = @('_KSub_ReadBuffer := ""')
        AnyOf    = @("1048576", "KSUB_BUFFER_MAX_BYTES")
    },

    # --- Workspace Cache Pruning (from test_unit_cleanup.ahk) ---
    @{
        Id       = "ksub_cache_prune_func"
        File     = "store\komorebi_sub.ahk"
        Desc     = "KomorebiSub has cache pruning function with TTL check"
        Patterns = @("KomorebiSub_PruneStaleCache()", "_KSub_CacheMaxAgeMs", "_KSub_WorkspaceCache.Delete(")
    },
    @{
        Id       = "heartbeat_calls_prune"
        File     = "store\store_server.ahk"
        Desc     = "Store_HeartbeatTick calls KomorebiSub_PruneStaleCache"
        Function = "Store_HeartbeatTick"
        Patterns = @("KomorebiSub_PruneStaleCache")
    },

    # --- Idle Timer Pause (from test_unit_cleanup.ahk) ---
    @{
        Id       = "icon_pump_idle_pause"
        File     = "store\icon_pump.ahk"
        Desc     = "Icon pump has idle-pause pattern with EnsureRunning"
        Patterns = @("_IP_IdleTicks", "_IP_IdleThreshold", "SetTimer(_IP_Tick, 0)", "IconPump_EnsureRunning()")
    },
    @{
        Id       = "proc_pump_idle_pause"
        File     = "store\proc_pump.ahk"
        Desc     = "Proc pump has idle-pause pattern with EnsureRunning"
        Patterns = @("_PP_IdleTicks", "_PP_IdleThreshold", "SetTimer(_PP_Tick, 0)", "ProcPump_EnsureRunning()")
    },
    @{
        Id       = "weh_idle_pause"
        File     = "store\winevent_hook.ahk"
        Desc     = "WinEvent hook has idle-pause pattern with EnsureTimerRunning"
        Patterns = @("_WEH_IdleTicks", "_WEH_IdleThreshold", "SetTimer(_WEH_ProcessBatch, 0)", "_WinEventHook_EnsureTimerRunning()")
    },
    @{
        Id       = "windowstore_wakes_pumps"
        File     = "store\windowstore.ahk"
        Desc     = "WindowStore wakes both pumps when enqueuing work"
        Patterns = @("IconPump_EnsureRunning()", "ProcPump_EnsureRunning()")
    },

    # --- Hot Path Static Buffers (from test_unit_cleanup.ahk) ---
    @{
        Id       = "gdip_drawtext_static_buf"
        File     = "gui\gui_gdip.ahk"
        Desc     = "Gdip_DrawText uses static rf buffer"
        Regex    = $true
        Patterns = @("Gdip_DrawText\([\s\S]*?static rf\s*:=\s*Buffer")
    },
    @{
        Id       = "gdip_drawcentered_static_buf"
        File     = "gui\gui_gdip.ahk"
        Desc     = "Gdip_DrawCenteredText uses static rf buffer"
        Regex    = $true
        Patterns = @("Gdip_DrawCenteredText\([\s\S]*?static rf\s*:=\s*Buffer")
    },
    @{
        Id       = "gui_repaint_static_buf"
        File     = "gui\gui_gdip.ahk"
        Desc     = "Gdip_GetBlendFunction uses static bf buffer"
        Patterns = @("static bf := Buffer")
    },
    @{
        Id       = "gui_recalchover_static_buf"
        File     = "gui\gui_input.ahk"
        Desc     = "GUI_RecalcHover uses static pt buffer"
        Regex    = $true
        Patterns = @("GUI_RecalcHover\([\s\S]*?static pt\s*:=\s*Buffer")
    },

    # --- Defensive Close (from test_unit_advanced.ahk) ---
    @{
        Id       = "gui_defensive_close"
        File     = "gui\gui_main.ahk"
        Desc     = "GUI has defensive IPC_PipeClient_Close before reconnect"
        Patterns = @("IPC_PipeClient_Close(gGUI_StoreClient)")
    },

    # --- Stale File Cleanup (from test_unit_advanced.ahk) ---
    @{
        Id       = "stale_file_cleanup"
        File     = "shared\setup_utils.ahk"
        Desc     = "Stale files array contains all expected temp files"
        Patterns = @("TEMP_WIZARD_STATE", "TEMP_UPDATE_STATE", "TEMP_INSTALL_UPDATE_STATE", "TEMP_ADMIN_TOGGLE_LOCK")
    },

    # --- Update Race Guard (from test_unit_advanced.ahk) ---
    @{
        Id       = "update_race_guard"
        File     = "shared\setup_utils.ahk"
        Desc     = "CheckForUpdates() has race guard (check, set, reset)"
        Patterns = @("if (g_UpdateCheckInProgress)", "g_UpdateCheckInProgress := true", "g_UpdateCheckInProgress := false")
    },

    # --- Shortcut Conflict Detection (from test_unit_advanced.ahk) ---
    @{
        Id       = "shortcut_conflict_detection"
        File     = "launcher\launcher_shortcuts.ahk"
        Desc     = "Shortcut creation has conflict detection"
        Patterns = @("if (FileExist(lnkPath))", "Shortcut Conflict")
        AnyOf    = @("existingTarget", "existing.TargetPath")
    },

    # --- Mismatch Dialog (from test_unit_advanced.ahk) ---
    @{
        Id       = "mismatch_optional_params"
        File     = "launcher\launcher_install.ahk"
        Desc     = "Mismatch dialog accepts optional parameters"
        Patterns = @('Launcher_ShowMismatchDialog(installedPath, title := "", message := "", question := "")')
    },
    @{
        Id       = "mismatch_result_handler"
        File     = "launcher\launcher_install.ahk"
        Desc     = "Mismatch result handler exists with Yes/Always handling"
        Patterns = @("_Launcher_HandleMismatchResult(", 'if (result = "Yes")')
        AnyOf    = @('if (result = "Always")', 'else if (result = "Always")')
    },
    @{
        Id       = "mismatch_same_version"
        File     = "launcher\launcher_install.ahk"
        Desc     = "Same-version mismatch has distinct dialog case"
        Patterns = @("else if (versionCompare = 0)")
        AnyOf    = @("Same Version", "same version")
    },

    # --- Exe Name Deduplication (from test_unit_setup.ahk) ---
    @{
        Id       = "exe_name_dedup"
        File     = "shared\process_utils.ahk"
        Desc     = "_ProcessUtils_BuildExeNameList uses StrLower + seenNames dedup"
        Patterns = @("_ProcessUtils_BuildExeNameList(", "StrLower(")
        AnyOf    = @("seenNames.Has(", "seenNames[")
    },

    # --- Process Detection & Kill Reliability (from test_unit_setup.ahk) ---
    @{
        Id       = "kill_process_pattern"
        File     = "shared\process_utils.ahk"
        Desc     = "ProcessUtils_KillByNameExceptSelf uses taskkill /F /IM with PID ne filter"
        Patterns = @("ProcessUtils_KillByNameExceptSelf(", "taskkill /F /IM", "PID ne")
    },
    @{
        Id       = "is_other_process_running"
        File     = "launcher\launcher_main.ahk"
        Desc     = "IsOtherProcessRunning uses tasklist /FI with PID ne"
        Patterns = @("Launcher_IsOtherProcessRunning(", "tasklist /FI", "PID ne")
    },
    @{
        Id       = "offer_stop_uses_helper"
        File     = "launcher\launcher_install.ahk"
        Desc     = "OfferToStopInstalledInstance calls IsOtherProcessRunning"
        Patterns = @("_Launcher_OfferToStopInstalledInstance(", "Launcher_IsOtherProcessRunning(")
    },

    # --- Wizard FirstRunCompleted (from test_unit_setup.ahk) ---
    @{
        Id       = "wizard_no_path_firstrun"
        File     = "launcher\launcher_wizard.ahk"
        Desc     = "Wizard 'No' path after UAC cancel sets FirstRunCompleted"
        Patterns = @('result = "No"', "FirstRunCompleted")
    }
)

# === Unified kill function delegates to ProcessUtils_KillAllAltTabbyExceptSelf ===
$CHECKS += @(
    @{
        Id       = "unified_kill_delegation"
        File     = "shared\process_utils.ahk"
        Desc     = "ProcessUtils_KillAltTabby delegates to _ProcessUtils_KillAllAltTabbyExceptSelf"
        Patterns = @("ProcessUtils_KillAltTabby(", "_ProcessUtils_KillAllAltTabbyExceptSelf(")
    }
)

# === Interaction Audit: Bug 1 - Exit handler kills subprocesses ===
$CHECKS += @(
    @{
        Id       = "exit_handler_kills_subprocesses"
        File     = "launcher\launcher_main.ahk"
        Desc     = "_Launcher_OnExit calls Launcher_ShutdownSubprocesses before mutex release"
        Function = "_Launcher_OnExit"
        Patterns = @("Launcher_ShutdownSubprocesses(")
    }
)

# === Interaction Audit: Bug 2 - Admin toggle result protocol ===
$CHECKS += @(
    @{
        Id       = "admin_toggle_write_result_exists"
        File     = "shared\setup_utils.ahk"
        Desc     = "_AdminToggle_WriteResult helper exists in setup_utils.ahk"
        Patterns = @("AdminToggle_WriteResult(result)", "TEMP_ADMIN_TOGGLE_LOCK")
    },
    @{
        Id       = "admin_toggle_handler_uses_write_result"
        File     = "alt_tabby.ahk"
        Desc     = "enable-admin-task handler uses _AdminToggle_WriteResult (not FileDelete)"
        Patterns = @('AdminToggle_WriteResult("ok")', 'AdminToggle_WriteResult("cancelled")', 'AdminToggle_WriteResult("failed")')
        NotPresent = @("FileDelete(TEMP_ADMIN_TOGGLE_LOCK)")
    },
    @{
        Id       = "admin_toggle_check_reads_content"
        File     = "launcher\launcher_tray.ahk"
        Desc     = "_AdminToggle_CheckComplete reads file content for result"
        Function = "_AdminToggle_CheckComplete"
        Patterns = @("FileRead(TEMP_ADMIN_TOGGLE_LOCK)", "IsNumber(content)")
    }
)

# === Interaction Audit: Bug 3 - Stale RunAsAdmin config sync ===
$CHECKS += @(
    @{
        Id       = "stale_admin_config_sync"
        File     = "launcher\launcher_main.ahk"
        Desc     = "_ShouldRedirectToScheduledTask syncs stale RunAsAdmin when task deleted"
        Regex    = $true
        Patterns = @("!AdminTaskExists\(\)\)\s*\{[\s\S]*?Setup_SetRunAsAdmin\(false\)")
    }
)

# === Admin Declined Marker: cleanup on enable/repair ===
$CHECKS += @(
    @{
        Id       = "admin_declined_marker_cleanup"
        File     = "alt_tabby.ahk"
        Desc     = "Enable/repair admin task modes clear admin-declined marker"
        Patterns = @("Setup_ClearAdminDeclinedMarker()")
    },
    @{
        Id       = "admin_declined_marker_check"
        File     = "launcher\launcher_main.ahk"
        Desc     = "_ShouldRedirectToScheduledTask checks admin-declined marker"
        Patterns = @("Setup_HasAdminDeclinedMarker()")
    }
)

# === Install Update State Constant Usage ===
$CHECKS += @(
    @{
        Id       = "install_update_constant"
        File     = "alt_tabby.ahk"
        Desc     = "update-installed mode uses TEMP_INSTALL_UPDATE_STATE constant"
        Patterns = @("TEMP_INSTALL_UPDATE_STATE")
    }
)

# === Code inspections migrated from test_unit_core.ahk ===

# Group A - Alt-Tab Eligibility (8 patterns in blacklist.ahk)
$CHECKS += @(
    @{
        Id       = "bl_eligibility_checks"
        File     = "shared\blacklist.ahk"
        Desc     = "_BL_IsAltTabEligible has all required Windows API checks"
        Patterns = @("WS_CHILD", "WS_EX_TOOLWINDOW", "WS_EX_NOACTIVATE", "GW_OWNER",
                      "IsWindowVisible", "DwmGetWindowAttribute", "WS_EX_APPWINDOW", "IsIconic")
    }
)

# Group B - Blacklist Regex Pre-compilation (3 checks)
$CHECKS += @(
    @{
        Id       = "bl_precompiled_regex_arrays"
        File     = "shared\blacklist.ahk"
        Desc     = "Blacklist has pre-compiled regex arrays for title and class"
        Patterns = @("gBlacklist_TitleRegex", "gBlacklist_ClassRegex")
    },
    @{
        Id       = "bl_ismatch_no_regexreplace"
        File     = "shared\blacklist.ahk"
        Desc     = "Blacklist_IsMatch does not call RegExReplace in hot path"
        Function = "Blacklist_IsMatch"
        NotPresent = @("RegExReplace")
    },
    @{
        Id       = "bl_compile_wildcard"
        File     = "shared\blacklist.ahk"
        Desc     = "_BL_CompileWildcard compile helper exists"
        Patterns = @("BL_CompileWildcard(")
    }
)

# Group C - WinEventHook Empty Title Filter (1 check)
# Note: Empty title filtering happens in batch processor via WinUtils_ProbeWindow.
# The probeTitle != "" check ensures system UI (like Task Switching) doesn't poison focus tracking.
$CHECKS += @(
    @{
        Id       = "weh_empty_title_filter"
        File     = "store\winevent_hook.ahk"
        Desc     = "WinEventHook filters empty-title windows from focus tracking"
        Patterns = @('probeTitle != ""', "NOT ELIGIBLE")
    }
)

# Group D - WinEventHook Focus Race Condition Guard (2 checks)
$CHECKS += @(
    @{
        Id       = "weh_focus_unknown_window"
        File     = "store\winevent_hook.ahk"
        Desc     = "_WEH_ProcessBatch has focus-on-unknown-window path (probes + upserts)"
        Patterns = @("NOT IN STORE", "UpsertWindow", "WinUtils_ProbeWindow", "winevent_focus_add")
    },
    @{
        Id       = "weh_focus_add_sets_tick"
        File     = "store\winevent_hook.ahk"
        Desc     = "Focus-add path sets lastActivatedTick and isFocused on new window"
        Patterns = @('probe["lastActivatedTick"]', 'probe["isFocused"]')
    }
)

# Group E - Bypass Mode Detection (3 checks)
$CHECKS += @(
    @{
        Id       = "bypass_process_list_parsing"
        File     = "gui\gui_interceptor.ahk"
        Desc     = "INT_ShouldBypassWindow has process list parsing (split, lowercase, trim)"
        Patterns = @("StrSplit(cfg.AltTabBypassProcesses", "StrLower", "Trim(")
    },
    @{
        Id       = "bypass_fullscreen_detection"
        File     = "gui\gui_interceptor.ahk"
        Desc     = "INT_IsFullscreenHwnd checks screen dimensions"
        Patterns = @("INT_IsFullscreenHwnd", "A_ScreenWidth", "A_ScreenHeight")
    },
    @{
        Id       = "bypass_hotkey_toggle"
        File     = "gui\gui_interceptor.ahk"
        Desc     = "INT_SetBypassMode toggles Tab hotkey On/Off"
        Patterns = @('Hotkey("$*Tab", "Off")', 'Hotkey("$*Tab", "On")')
    }
)

# Group F - Config Validation Completeness (registry-driven clamping)
$CHECKS += @(
    @{
        Id       = "config_validation_completeness_loader"
        File     = "shared\config_loader.ahk"
        Desc     = "_CL_ValidateSettings uses registry-driven clamping loop"
        Patterns = @('entry.HasOwnProp("min")', ':= clamp(cfg.%entry.g%')
    }
    @{
        Id       = "config_validation_completeness_registry"
        File     = "shared\config_registry.ahk"
        Desc     = "Config registry has sufficient min/max constraint entries"
        Patterns = @("min:")
        MinCount = 50
    }
)

# === Activation MRU Gating (Regression guards for phantom MRU bug) ===

# _GUI_RobustActivate must return bool (not void)
$CHECKS += @(
    @{
        Id       = "activate_returns_bool"
        File     = "gui\gui_state.ahk"
        Desc     = "_GUI_RobustActivate returns success/failure boolean"
        Function = "_GUI_RobustActivate"
        Patterns = @("return true", "return false")
    }
)

# _GUI_RobustActivate verifies foreground after SetForegroundWindow
$CHECKS += @(
    @{
        Id       = "activate_verifies_foreground"
        File     = "gui\gui_state.ahk"
        Desc     = "_GUI_RobustActivate calls GetForegroundWindow to verify activation"
        Function = "_GUI_RobustActivate"
        Patterns = @("GetForegroundWindow")
    }
)

# Same-workspace path gates MRU on activation success
$CHECKS += @(
    @{
        Id       = "activate_gated_mru"
        File     = "gui\gui_state.ahk"
        Desc     = "_GUI_ActivateItem gates _GUI_UpdateLocalMRU on _GUI_RobustActivate success"
        Function = "_GUI_ActivateItem"
        Patterns = @("if (_GUI_RobustActivate(hwnd))")
    }
)

# _GUI_UpdateLocalMRU does NOT release Critical (cross-function leak fix)
$CHECKS += @(
    @{
        Id       = "mru_update_no_critical_off"
        File     = "gui\gui_state.ahk"
        Desc     = "_GUI_UpdateLocalMRU does not call Critical Off (callers hold Critical)"
        Function = "_GUI_UpdateLocalMRU"
        NotPresent = @('Critical "Off"')
    }
)

# isFocused does NOT trigger MRU re-sort (store/GUI classification desync fix)
$CHECKS += @(
    @{
        Id       = "isfocused_no_mru_trigger"
        File     = "gui\gui_store.ahk"
        Desc     = "isFocused delta handler does NOT set mruChanged (content-only field)"
        Function = "_GUI_ApplyDelta"
        Regex    = $true
        NotPresent = @('isFocused[\s\S]{0,50}mruChanged\s*:=\s*true')
    }
)

# Path 1.5 validates sort invariant after move-to-front
$CHECKS += @(
    @{
        Id       = "path15_sort_invariant"
        File     = "store\windowstore.ahk"
        Desc     = "Path 1.5 projection validates sort invariant after move-to-front"
        Regex    = $true
        Patterns = @('lastActivatedTick\s*<\s*sortedRecs')
    }
)

# === Run checks ===

$passed = 0
$failed = 0
$skipped = 0
$failures = @()

foreach ($check in $CHECKS) {
    $content = Get-CachedContent $check.File

    if ($null -eq $content) {
        $skipped++
        continue
    }

    # If Function key is set, extract function body
    $searchText = $content
    if ($check.ContainsKey('Function') -and $check.Function) {
        $body = Extract-FunctionBody $content $check.Function
        if ($null -eq $body) {
            $failed++
            $failures += "$($check.Id): Could not extract function '$($check.Function)' from $($check.File)"
            continue
        }
        $searchText = $body
    }

    $isRegex = $check.ContainsKey('Regex') -and $check.Regex

    # Check NotPresent patterns (must NOT match)
    if ($check.ContainsKey('NotPresent') -and $check.NotPresent) {
        $foundBad = $false
        foreach ($pat in $check.NotPresent) {
            if ($isRegex) {
                if ($searchText -match $pat) { $foundBad = $true; break }
            } else {
                if ($searchText.Contains($pat)) { $foundBad = $true; break }
            }
        }
        if ($foundBad) {
            $failed++
            $failures += "$($check.Id): $($check.Desc) - forbidden pattern found in $($check.File)"
            continue
        }
        # If there are no Patterns/AnyOf, this is a pure NotPresent check
        if (-not $check.ContainsKey('Patterns') -and -not $check.ContainsKey('AnyOf')) {
            $passed++
            continue
        }
    }

    # Check required Patterns (ALL must match)
    $allPresent = $true
    $missingPatterns = @()
    if ($check.ContainsKey('Patterns') -and $check.Patterns) {
        foreach ($pat in $check.Patterns) {
            $found = $false
            if ($isRegex) {
                $found = $searchText -match $pat
            } else {
                $found = $searchText.Contains($pat)
            }
            if (-not $found) {
                $allPresent = $false
                $missingPatterns += $pat
            }
        }
    }

    # Check AnyOf patterns (at least ONE must match)
    $anyOfOk = $true
    if ($check.ContainsKey('AnyOf') -and $check.AnyOf) {
        $anyOfOk = $false
        foreach ($pat in $check.AnyOf) {
            if ($isRegex) {
                if ($searchText -match $pat) { $anyOfOk = $true; break }
            } else {
                if ($searchText.Contains($pat)) { $anyOfOk = $true; break }
            }
        }
    }

    # Check MinCount (count occurrences of Patterns[0], require >= MinCount)
    $minCountOk = $true
    if ($check.ContainsKey('MinCount') -and $check.MinCount -gt 0 -and $check.ContainsKey('Patterns') -and $check.Patterns.Count -gt 0) {
        $countPat = $check.Patterns[0]
        $actualCount = 0
        $searchIdx = 0
        while (($searchIdx = $searchText.IndexOf($countPat, $searchIdx)) -ge 0) {
            $actualCount++
            $searchIdx += $countPat.Length
        }
        if ($actualCount -lt $check.MinCount) {
            $minCountOk = $false
        }
    }

    if ($allPresent -and $anyOfOk -and $minCountOk) {
        $passed++
    } else {
        $failed++
        $detail = ""
        if ($missingPatterns.Count -gt 0) {
            $detail = " missing: $($missingPatterns -join ', ')"
        }
        if (-not $anyOfOk) {
            $detail += " none of AnyOf matched"
        }
        if (-not $minCountOk) {
            $detail += " MinCount: found $actualCount, expected >= $($check.MinCount)"
        }
        $failures += "$($check.Id): $($check.Desc) -$detail in $($check.File)"
    }
}

$totalSw.Stop()

# === Report ===

$timingLine = "  Timing: total=$($totalSw.ElapsedMilliseconds)ms"
$statsLine  = "  Stats:  $($CHECKS.Count) checks ($passed passed, $failed failed, $skipped skipped)"

if ($failed -gt 0) {
    Write-Host ""
    Write-Host "  FAIL: $failed code pattern check(s) failed." -ForegroundColor Red
    foreach ($f in $failures) {
        Write-Host "    $f" -ForegroundColor Red
    }
    if ($BatchMode) { return 1 }
    Write-Host ""
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 1
} else {
    if ($BatchMode) { return 0 }
    Write-Host "  PASS: All $passed code pattern checks passed" -ForegroundColor Green
    Write-Host $timingLine -ForegroundColor Cyan
    Write-Host $statsLine -ForegroundColor Cyan
    exit 0
}
