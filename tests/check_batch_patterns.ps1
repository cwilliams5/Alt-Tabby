# check_batch_patterns.ps1 - Batched forbidden/outdated code pattern checks
# Combines 4 pattern checks into one PowerShell process with shared file cache.
# Sub-checks: code_patterns, logging_hygiene, v1_patterns, send_patterns
#
# Usage: powershell -File tests\check_batch_patterns.ps1 [-SourceDir "path\to\src"]
# Exit codes: 0 = all pass, 1 = any check failed

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

$projectRoot = (Resolve-Path "$SourceDir\..").Path

# === Shared file cache (single read for all sub-checks) ===
$allFiles = @(Get-ChildItem -Path $SourceDir -Filter "*.ahk" -Recurse |
    Where-Object { $_.FullName -notlike "*\lib\*" })
$fileCache = @{}        # fullPath -> string[] (lines)
$fileCacheText = @{}    # fullPath -> string (joined text)
$relToFull = @{}        # relPath (from src/) -> fullPath
foreach ($f in $allFiles) {
    $lines = [System.IO.File]::ReadAllLines($f.FullName)
    $fileCache[$f.FullName] = $lines
    $fileCacheText[$f.FullName] = [string]::Join("`n", $lines)
    $relPath = $f.FullName
    if ($relPath.StartsWith($SourceDir)) {
        $relPath = $relPath.Substring($SourceDir.Length).TrimStart('\', '/')
    }
    $relToFull[$relPath] = $f.FullName
}

# === Sub-check tracking ===
$subTimings = [System.Collections.ArrayList]::new()
$anyFailed = $false
$failOutput = [System.Text.StringBuilder]::new()

# === Shared helpers ===

function BP_Clean-Line {
    param([string]$line)
    if ($line.Length -eq 0) { return '' }
    $trimmed = $line.TrimStart()
    if ($trimmed.Length -eq 0) { return '' }
    if ($trimmed[0] -eq ';') { return '' }
    $cleaned = $line
    if ($line.IndexOf('"') -ge 0) {
        $cleaned = $cleaned -replace '"[^"]*"', '""'
    }
    if ($line.IndexOf("'") -ge 0) {
        $cleaned = $cleaned -replace "'[^']*'", "''"
    }
    if ($cleaned.IndexOf(';') -ge 0) {
        $cleaned = $cleaned -replace '\s;.*$', ''
    }
    return $cleaned
}

function BP_Extract-FunctionBody {
    param([string]$Code, [string]$FuncName)
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

# ============================================================
# Sub-check 1: code_patterns
# Table-driven production code pattern verification
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$CHECKS = @(
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
    @{
        Id       = "ksub_no_undefined_log"
        File     = "store\komorebi_sub.ahk"
        Desc     = "No undefined _KSub_Log() calls (should be KSub_DiagLog)"
        NotPresent = @("_KSub_Log(")
    },
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
        Patterns = @("_Store_OnClientDisconnect)", "_Store_OnClientDisconnect(hPipe)", "gStore_ClientState.Delete(")
    },
    @{
        Id       = "ksub_buffer_overflow"
        File     = "store\komorebi_sub.ahk"
        Desc     = "Komorebi subscription has 1MB buffer overflow protection"
        Patterns = @('_KSub_ReadBuffer := ""')
        AnyOf    = @("1048576", "KSUB_BUFFER_MAX_BYTES")
    },
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
    @{
        Id       = "gui_defensive_close"
        File     = "gui\gui_main.ahk"
        Desc     = "GUI has defensive IPC_PipeClient_Close before reconnect"
        Patterns = @("IPC_PipeClient_Close(gGUI_StoreClient)")
    },
    @{
        Id       = "stale_file_cleanup"
        File     = "shared\setup_utils.ahk"
        Desc     = "Stale files array contains all expected temp files"
        Patterns = @("TEMP_WIZARD_STATE", "TEMP_UPDATE_STATE", "TEMP_INSTALL_UPDATE_STATE", "TEMP_ADMIN_TOGGLE_LOCK")
    },
    @{
        Id       = "update_race_guard"
        File     = "shared\setup_utils.ahk"
        Desc     = "CheckForUpdates() has race guard (check, set, reset)"
        Patterns = @("if (g_UpdateCheckInProgress)", "g_UpdateCheckInProgress := true", "g_UpdateCheckInProgress := false")
    },
    @{
        Id       = "shortcut_conflict_detection"
        File     = "launcher\launcher_shortcuts.ahk"
        Desc     = "Shortcut creation has conflict detection"
        Patterns = @("if (FileExist(lnkPath))", "Shortcut Conflict")
        AnyOf    = @("existingTarget", "existing.TargetPath")
    },
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
    @{
        Id       = "exe_name_dedup"
        File     = "shared\process_utils.ahk"
        Desc     = "_ProcessUtils_BuildExeNameList uses StrLower + seenNames dedup"
        Patterns = @("_ProcessUtils_BuildExeNameList(", "StrLower(")
        AnyOf    = @("seenNames.Has(", "seenNames[")
    },
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
    @{
        Id       = "wizard_no_path_firstrun"
        File     = "launcher\launcher_wizard.ahk"
        Desc     = "Wizard 'No' path after UAC cancel sets FirstRunCompleted"
        Patterns = @('result = "No"', "FirstRunCompleted")
    },
    @{
        Id       = "unified_kill_delegation"
        File     = "shared\process_utils.ahk"
        Desc     = "ProcessUtils_KillAltTabby delegates to _ProcessUtils_KillAllAltTabbyExceptSelf"
        Patterns = @("ProcessUtils_KillAltTabby(", "_ProcessUtils_KillAllAltTabbyExceptSelf(")
    },
    @{
        Id       = "exit_handler_kills_subprocesses"
        File     = "launcher\launcher_main.ahk"
        Desc     = "_Launcher_OnExit calls Launcher_ShutdownSubprocesses before mutex release"
        Function = "_Launcher_OnExit"
        Patterns = @("Launcher_ShutdownSubprocesses(")
    },
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
    },
    @{
        Id       = "stale_admin_config_sync"
        File     = "launcher\launcher_main.ahk"
        Desc     = "_ShouldRedirectToScheduledTask syncs stale RunAsAdmin when task deleted"
        Regex    = $true
        Patterns = @("!AdminTaskExists\(\)\)\s*\{[\s\S]*?Setup_SetRunAsAdmin\(false\)")
    },
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
    },
    @{
        Id       = "install_update_constant"
        File     = "alt_tabby.ahk"
        Desc     = "update-installed mode uses TEMP_INSTALL_UPDATE_STATE constant"
        Patterns = @("TEMP_INSTALL_UPDATE_STATE")
    },
    @{
        Id       = "bl_eligibility_checks"
        File     = "shared\blacklist.ahk"
        Desc     = "_BL_IsAltTabEligible has all required Windows API checks"
        Patterns = @("WS_CHILD", "WS_EX_TOOLWINDOW", "WS_EX_NOACTIVATE", "GW_OWNER",
                      "IsWindowVisible", "DwmGetWindowAttribute", "WS_EX_APPWINDOW", "IsIconic")
    },
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
    },
    @{
        Id       = "weh_empty_title_filter"
        File     = "store\winevent_hook.ahk"
        Desc     = "WinEventHook filters empty-title windows from focus tracking"
        Patterns = @('probeTitle != ""', "NOT ELIGIBLE")
    },
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
    },
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
    },
    @{
        Id       = "config_validation_completeness_loader"
        File     = "shared\config_loader.ahk"
        Desc     = "_CL_ValidateSettings uses registry-driven clamping loop"
        Patterns = @('entry.HasOwnProp("min")', ':= clamp(cfg.%entry.g%')
    },
    @{
        Id       = "config_validation_completeness_registry"
        File     = "shared\config_registry.ahk"
        Desc     = "Config registry has sufficient min/max constraint entries"
        Patterns = @("min:")
        MinCount = 50
    },
    @{
        Id       = "activate_returns_bool"
        File     = "gui\gui_state.ahk"
        Desc     = "_GUI_RobustActivate returns success/failure boolean"
        Function = "_GUI_RobustActivate"
        Patterns = @("return true", "return false")
    },
    @{
        Id       = "activate_verifies_foreground"
        File     = "gui\gui_state.ahk"
        Desc     = "_GUI_RobustActivate calls GetForegroundWindow to verify activation"
        Function = "_GUI_RobustActivate"
        Patterns = @("GetForegroundWindow")
    },
    @{
        Id       = "activate_gated_mru"
        File     = "gui\gui_state.ahk"
        Desc     = "_GUI_ActivateItem gates _GUI_UpdateLocalMRU on _GUI_RobustActivate success"
        Function = "_GUI_ActivateItem"
        Patterns = @("if (_GUI_RobustActivate(hwnd))")
    },
    @{
        Id       = "mru_update_no_critical_off"
        File     = "gui\gui_state.ahk"
        Desc     = "_GUI_UpdateLocalMRU does not call Critical Off (callers hold Critical)"
        Function = "_GUI_UpdateLocalMRU"
        NotPresent = @('Critical "Off"')
    },
    @{
        Id       = "isfocused_no_mru_trigger"
        File     = "gui\gui_store.ahk"
        Desc     = "isFocused delta handler does NOT set mruChanged (content-only field)"
        Function = "_GUI_ApplyDelta"
        Regex    = $true
        NotPresent = @('isFocused[\s\S]{0,50}mruChanged\s*:=\s*true')
    },
    @{
        Id       = "path15_sort_invariant"
        File     = "store\windowstore.ahk"
        Desc     = "Path 1.5 projection validates sort invariant after move-to-front"
        Regex    = $true
        Patterns = @('lastActivatedTick\s*<\s*sortedRecs')
    },
    @{
        Id       = "ghost_window_detection"
        File     = "store\windowstore.ahk"
        Desc     = "ValidateExistence detects ghost windows via visibility+cloaked+minimized checks"
        Function = "WindowStore_ValidateExistence"
        Patterns = @("IsWindowVisible", "DwmGetWindowAttribute", "IsIconic")
    },
    @{
        Id       = "snapshot_blocking_during_async"
        File     = "gui\gui_store.ahk"
        Desc     = "Snapshot handler checks gGUI_PendingPhase (async activation guard)"
        Function = "GUI_OnStoreMessage"
        Patterns = @("gGUI_PendingPhase")
    },
    @{
        Id       = "local_mru_staleness_check"
        File     = "gui\gui_store.ahk"
        Desc     = "Snapshot handler has local MRU staleness check"
        Patterns = @("gGUI_LastLocalMRUTick")
    }
)

$cpPassed = 0
$cpFailed = 0
$cpSkipped = 0
$cpFailures = @()

foreach ($check in $CHECKS) {
    # Resolve content from shared cache
    $fullPath = $null
    if ($relToFull.ContainsKey($check.File)) {
        $fullPath = $relToFull[$check.File]
    }
    $content = if ($fullPath) { $fileCacheText[$fullPath] } else { $null }

    if ($null -eq $content) {
        $cpSkipped++
        continue
    }

    # If Function key is set, extract function body
    $searchText = $content
    if ($check.ContainsKey('Function') -and $check.Function) {
        $body = BP_Extract-FunctionBody $content $check.Function
        if ($null -eq $body) {
            $cpFailed++
            $cpFailures += "$($check.Id): Could not extract function '$($check.Function)' from $($check.File)"
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
            $cpFailed++
            $cpFailures += "$($check.Id): $($check.Desc) - forbidden pattern found in $($check.File)"
            continue
        }
        if (-not $check.ContainsKey('Patterns') -and -not $check.ContainsKey('AnyOf')) {
            $cpPassed++
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

    # Check MinCount
    $minCountOk = $true
    $actualCount = 0
    if ($check.ContainsKey('MinCount') -and $check.MinCount -gt 0 -and $check.ContainsKey('Patterns') -and $check.Patterns.Count -gt 0) {
        $countPat = $check.Patterns[0]
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
        $cpPassed++
    } else {
        $cpFailed++
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
        $cpFailures += "$($check.Id): $($check.Desc) -$detail in $($check.File)"
    }
}

if ($cpFailed -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $cpFailed code pattern check(s) failed.")
    foreach ($f in $cpFailures) {
        [void]$failOutput.AppendLine("    $f")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_code_patterns"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 2: logging_hygiene
# Catches logging anti-patterns
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lhIssues = @()

# Check 1: Unconditional FileAppend in catch blocks
$lhCheck1Files = @(
    (Join-Path $SourceDir "gui\gui_state.ahk"),
    (Join-Path $SourceDir "store\komorebi_sub.ahk"),
    (Join-Path $SourceDir "shared\ipc_pipe.ahk")
)
foreach ($filePath in $lhCheck1Files) {
    if (-not $fileCache.ContainsKey($filePath)) { continue }
    $content = $fileCacheText[$filePath]
    $fileName = [System.IO.Path]::GetFileName($filePath)
    if ($content -match 'catch[^{]*\{[^}]*FileAppend\([^,]+,\s*A_Temp\s*["\\]+[a-z_]+\.txt') {
        $lhIssues += [PSCustomObject]@{
            Check = 'Unconditional FileAppend'; File = $fileName
            Detail = 'FileAppend in catch block writes to hardcoded temp path'
        }
    }
}

# Check 2: Duplicate *_Log / *_DiagLog function patterns
$lhCheck2 = @(
    @{ Path = (Join-Path $SourceDir "store\komorebi_sub.ahk"); Prefix = '_KSub' },
    @{ Path = (Join-Path $SourceDir "store\store_server.ahk"); Prefix = 'Store' },
    @{ Path = (Join-Path $SourceDir "gui\gui_state.ahk");     Prefix = '_GUI' }
)
foreach ($entry in $lhCheck2) {
    if (-not $fileCache.ContainsKey($entry.Path)) { continue }
    $content = $fileCacheText[$entry.Path]
    $fileName = [System.IO.Path]::GetFileName($entry.Path)
    $prefix = $entry.Prefix
    $hasLegacyLog = $content -match "${prefix}_Log\s*\([^)]*\)\s*\{"
    $hasDiagLog   = $content -match "${prefix}_DiagLog\s*\([^)]*\)\s*\{"
    if ($hasLegacyLog -and $hasDiagLog) {
        $lhIssues += [PSCustomObject]@{
            Check = 'Duplicate logging'; File = $fileName
            Detail = "Has both ${prefix}_Log and ${prefix}_DiagLog (should unify)"
        }
    }
}

# Check 3: Legacy *_DebugLog global variables
foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*;') { continue }
        if ($line -match 'global\s+\w+_DebugLog\s*:=') {
            $relPath = $file.FullName
            if ($relPath.StartsWith($SourceDir)) {
                $relPath = $relPath.Substring($SourceDir.Length).TrimStart('\', '/')
            }
            $lhIssues += [PSCustomObject]@{
                Check = 'Legacy DebugLog'; File = $relPath
                Detail = "Line $($i + 1): legacy *_DebugLog variable (convert to cfg.Diag* pattern)"
            }
        }
    }
}

# Check 4: _Store_LogError must be unconditional
$storeServerPath = Join-Path $SourceDir "store\store_server.ahk"
if ($fileCache.ContainsKey($storeServerPath)) {
    $content = $fileCacheText[$storeServerPath]
    $hasLogError = $content -match '_Store_LogError\(msg\)'
    if (-not $hasLogError) {
        $lhIssues += [PSCustomObject]@{
            Check = '_Store_LogError missing'; File = 'store_server.ahk'
            Detail = '_Store_LogError(msg) function not found'
        }
    } else {
        if ($content -match '_Store_LogError\(msg\)\s*\{([^}]+)\}') {
            $funcBody = $Matches[1]
            if ($funcBody -match 'cfg\.Diag') {
                $lhIssues += [PSCustomObject]@{
                    Check = '_Store_LogError gated'; File = 'store_server.ahk'
                    Detail = '_Store_LogError should be unconditional (no cfg.Diag check)'
                }
            }
        }
    }
}

if ($lhIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($lhIssues.Count) logging hygiene issue(s) detected.")
    foreach ($issue in $lhIssues) {
        [void]$failOutput.AppendLine("    [$($issue.Check)] $($issue.File): $($issue.Detail)")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_logging_hygiene"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 3: v1_patterns
# Catches AHK v1 holdover patterns
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$V1_COMMANDS = @(
    'IfEqual', 'IfNotEqual', 'IfGreater', 'IfLess',
    'IfInString', 'IfNotInString',
    'StringLeft', 'StringRight', 'StringMid', 'StringLen',
    'StringReplace', 'StringGetPos',
    'StringLower', 'StringUpper',
    'StringTrimLeft', 'StringTrimRight',
    'EnvAdd', 'EnvSub', 'EnvMult', 'EnvDiv',
    'SetEnv', 'Transform'
)
$v1CommandPattern = '^(' + ($V1_COMMANDS -join '|') + ')(\s|,|$)'
$v1FuncPattern = '\bFunc\s*\(\s*"'
$v1LegacyVarPattern = '(?<!\.)%(\w+)%'
$v1BuiltinVarExclude = '^A_'

$v1Issues = @()

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $inBlockComment = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $rawLine = $lines[$i]
        $lineNum = $i + 1

        if ($inBlockComment) {
            if ($rawLine -match '\*/') { $inBlockComment = $false }
            continue
        }
        if ($rawLine -match '^\s*/\*') { $inBlockComment = $true; continue }

        $cleaned = BP_Clean-Line $rawLine
        if ([string]::IsNullOrWhiteSpace($cleaned)) { continue }

        # Check 1: Func("Name")
        if ($cleaned -match $v1FuncPattern) {
            $v1Issues += [PSCustomObject]@{
                File = $file.FullName; Line = $lineNum
                Pattern = 'Func("Name")'; Text = $rawLine.TrimStart()
            }
        }

        # Check 2: %var% legacy dereferencing
        $varMatches = [regex]::Matches($cleaned, $v1LegacyVarPattern)
        foreach ($m in $varMatches) {
            $varName = $m.Groups[1].Value
            if ($varName -match $v1BuiltinVarExclude) { continue }
            if ($rawLine -match 'VarRef') { continue }
            $v1Issues += [PSCustomObject]@{
                File = $file.FullName; Line = $lineNum
                Pattern = '%var%'; Text = $rawLine.TrimStart()
            }
            break
        }

        # Check 3: Legacy v1 command syntax
        $trimmed = $cleaned.TrimStart()
        if ($trimmed -match $v1CommandPattern) {
            $v1Issues += [PSCustomObject]@{
                File = $file.FullName; Line = $lineNum
                Pattern = 'v1 command'; Text = $rawLine.TrimStart()
            }
        }
    }
}

if ($v1Issues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($v1Issues.Count) AHK v1 pattern(s) detected.")
    [void]$failOutput.AppendLine("  These patterns are not valid in AHK v2 and should be replaced.")
    $grouped = $v1Issues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        $relPath = $group.Name
        if ($relPath.StartsWith($SourceDir)) {
            $relPath = $relPath.Substring($SourceDir.Length).TrimStart('\', '/')
        }
        [void]$failOutput.AppendLine("    ${relPath}:")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line) [$($issue.Pattern)]: $($issue.Text)")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_v1_patterns"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 4: send_patterns
# Send/Hook safety enforcement
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$spIssues = [System.Collections.ArrayList]::new()
$guiMainPath = Join-Path $SourceDir "gui\gui_main.ahk"
$hasSendModeEvent = $false

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $isGuiFile = $file.FullName -like "*\gui\*"

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $rawLine = $lines[$i]
        $cleaned = BP_Clean-Line $rawLine
        if ($cleaned -eq '') { continue }
        if ($rawLine -match 'lint-ignore:\s*send-pattern') { continue }

        # Rule 1: Forbidden SendMode("Input") or SendMode("InputThenPlay")
        if ($rawLine -match 'SendMode\s*\(\s*"(Input|InputThenPlay)"\s*\)') {
            [void]$spIssues.Add([PSCustomObject]@{
                File = $relPath; Line = $i + 1
                Message = "Forbidden SendMode: $($rawLine.Trim())"; Rule = "SendMode"
            })
        }

        # Rule 2: Forbidden AHK SendInput command in gui/ files
        if ($isGuiFile) {
            if ($cleaned -match '(?<!\w)SendInput[\s,\(]' -and
                $cleaned -notmatch 'DllCall\(' -and
                $cleaned -notmatch 'SendInput\s*\(' -and
                $cleaned -notmatch '^\s*;') {
                [void]$spIssues.Add([PSCustomObject]@{
                    File = $relPath; Line = $i + 1
                    Message = "SendInput in GUI file (uninstalls keyboard hooks): $($rawLine.Trim())"
                    Rule = "SendInput"
                })
            }
        }

        # Rule 3: Track SendMode("Event") in gui_main.ahk
        if ($file.FullName -eq $guiMainPath -and $rawLine -match 'SendMode\s*\(\s*"Event"\s*\)') {
            $hasSendModeEvent = $true
        }
    }
}

if (-not $hasSendModeEvent) {
    [void]$spIssues.Add([PSCustomObject]@{
        File = "src\gui\gui_main.ahk"; Line = 0
        Message = "Missing required SendMode(`"Event`") declaration"; Rule = "SendModeEvent"
    })
}

if ($spIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($spIssues.Count) Send/Hook safety issue(s) found.")
    [void]$failOutput.AppendLine("  SendMode(`"Input`") and SendInput uninstall keyboard hooks, causing lost keypresses.")
    [void]$failOutput.AppendLine("  Fix: use SendMode(`"Event`") and avoid raw SendInput in GUI files.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: send-pattern' on the offending line.")
    $grouped = $spIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            if ($issue.Line -gt 0) {
                [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Message)")
            } else {
                [void]$failOutput.AppendLine("      $($issue.Message)")
            }
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_send_patterns"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All pattern checks passed (code_patterns, logging_hygiene, v1_patterns, send_patterns)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_patterns_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
