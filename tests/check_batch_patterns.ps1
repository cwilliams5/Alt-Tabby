# check_batch_patterns.ps1 - Batched forbidden/outdated code pattern checks
# Combines 5 pattern checks into one PowerShell process with shared file cache.
# Sub-checks: code_patterns, logging_hygiene, v1_patterns, send_patterns, display_fields, viewer_columns, map_dot_access, dirty_tracking, direct_record_mutation, fr_guard, copydata_contract, scan_pairing, setcallbacks_wiring, cache_path_invariants, numeric_string_comparison
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
    $text = [System.IO.File]::ReadAllText($f.FullName)
    $fileCacheText[$f.FullName] = $text
    $lines = $text -split "`r?`n"
    $fileCache[$f.FullName] = $lines
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

# === Pre-compiled regex constants (JIT-compiled to IL, used by BP_Clean-Line) ===
$script:RX_DBL_STR  = [regex]::new('"[^"]*"', 'Compiled')
$script:RX_SGL_STR  = [regex]::new("'[^']*'", 'Compiled')
$script:RX_CMT_TAIL = [regex]::new('\s;.*$', 'Compiled')

# === Shared helpers ===

function BP_Clean-Line {
    param([string]$line)
    if ($line.Length -eq 0) { return '' }
    $trimmed = $line.TrimStart()
    if ($trimmed.Length -eq 0) { return '' }
    if ($trimmed[0] -eq ';') { return '' }
    $cleaned = $line
    if ($line.IndexOf('"') -ge 0) {
        $cleaned = $script:RX_DBL_STR.Replace($cleaned, '""')
    }
    if ($line.IndexOf("'") -ge 0) {
        $cleaned = $script:RX_SGL_STR.Replace($cleaned, "''")
    }
    if ($cleaned.IndexOf(';') -ge 0) {
        $cleaned = $script:RX_CMT_TAIL.Replace($cleaned, '')
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
        Desc     = "Gdip_Shutdown() exists as D2D cleanup shim"
        Patterns = @("Gdip_Shutdown()", "D2D_DisposeResources()")
    },
    @{
        Id       = "d2d_dispose_resources"
        File     = "gui\gui_gdip.ahk"
        Desc     = "D2D_DisposeResources() clears all D2D resource maps"
        Patterns = @("gD2D_Res := Map()", "gD2D_BrushCache := Map()")
    },
    @{
        Id       = "d2d_shutdown_all"
        File     = "gui\gui_overlay.ahk"
        Desc     = "D2D_ShutdownAll() releases RT and factories"
        Patterns = @("D2D_DisposeResources()", "gD2D_RT := 0", "gDW_Factory := 0", "gD2D_Factory := 0")
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
        Id       = "gui_onexit_gdip"
        File     = "gui\gui_main.ahk"
        Desc     = "GUI _GUI_OnExit calls Gdip_Shutdown() and D2D_ShutdownAll()"
        Function = "_GUI_OnExit"
        Patterns = @("Gdip_Shutdown()", "D2D_ShutdownAll()")
    },
    @{
        Id       = "ksub_no_undefined_log"
        File     = "core\komorebi_sub.ahk"
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
        Id       = "ksub_buffer_overflow"
        File     = "core\komorebi_sub.ahk"
        Desc     = "Komorebi subscription has 1MB buffer overflow protection"
        Patterns = @('_KSub_ReadBuffer := ""')
        AnyOf    = @("1048576", "KSUB_BUFFER_MAX_BYTES")
    },
    @{
        Id       = "ksub_cache_prune_func"
        File     = "core\komorebi_sub.ahk"
        Desc     = "KomorebiSub has cache pruning function with TTL check"
        Patterns = @("KomorebiSub_PruneStaleCache()", "_KSub_CacheMaxAgeMs", "_KSub_WorkspaceCache.Delete(")
    },
    @{
        Id       = "icon_pump_idle_pause"
        File     = "core\icon_pump.ahk"
        Desc     = "Icon pump has idle-pause pattern with EnsureRunning"
        Patterns = @("_IP_IdleTicks", "_IP_IdleThreshold", "SetTimer(_IP_Tick, 0)", "IconPump_EnsureRunning()")
    },
    @{
        Id       = "proc_pump_idle_pause"
        File     = "core\proc_pump.ahk"
        Desc     = "Proc pump has idle-pause pattern with EnsureRunning"
        Patterns = @("_PP_IdleTicks", "_PP_IdleThreshold", "SetTimer(_PP_Tick, 0)", "ProcPump_EnsureRunning()")
    },
    @{
        Id       = "weh_idle_pause"
        File     = "core\winevent_hook.ahk"
        Desc     = "WinEvent hook has idle-pause pattern with EnsureTimerRunning"
        Patterns = @("_WEH_IdleTicks", "_WEH_IdleThreshold", "SetTimer(_WEH_ProcessBatch, 0)", "_WinEventHook_EnsureTimerRunning()")
    },
    @{
        Id       = "windowlist_wakes_pumps"
        File     = "shared\window_list.ahk"
        Desc     = "WindowList wakes both pumps when enqueuing work"
        Patterns = @("IconPump_EnsureRunning()", "ProcPump_EnsureRunning()")
    },
    @{
        Id       = "d2d_drawtext_static_buf"
        File     = "gui\gui_gdip.ahk"
        Desc     = "D2D_DrawTextLeft uses static rect buffer"
        Regex    = $true
        Patterns = @("D2D_DrawTextLeft\([\s\S]*?static rect\s*:=\s*Buffer")
    },
    @{
        Id       = "d2d_drawcentered_static_buf"
        File     = "gui\gui_gdip.ahk"
        Desc     = "D2D_DrawTextCentered uses static rect buffer"
        Regex    = $true
        Patterns = @("D2D_DrawTextCentered\([\s\S]*?static rect\s*:=\s*Buffer")
    },
    @{
        Id       = "d2d_fillroundrect_static_buf"
        File     = "gui\gui_gdip.ahk"
        Desc     = "D2D_FillRoundRect uses static rrBuf buffer"
        Patterns = @("static rrBuf := Buffer")
    },
    @{
        Id       = "gui_recalchover_static_buf"
        File     = "gui\gui_input.ahk"
        Desc     = "GUI_RecalcHover uses static pt buffer"
        Regex    = $true
        Patterns = @("GUI_RecalcHover\([\s\S]*?static pt\s*:=\s*Buffer")
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
        File     = "core\winevent_hook.ahk"
        Desc     = "WinEventHook filters empty-title windows from focus tracking"
        Patterns = @('probeTitle != ""', "NOT ELIGIBLE")
    },
    @{
        Id       = "weh_focus_unknown_window"
        File     = "core\winevent_hook.ahk"
        Desc     = "_WEH_ProcessBatch has focus-on-unknown-window path (probes + upserts)"
        Patterns = @("NOT IN STORE", "UpsertWindow", "WinUtils_ProbeWindow", "winevent_focus_add")
    },
    @{
        Id       = "weh_focus_add_sets_tick"
        File     = "core\winevent_hook.ahk"
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
        Desc     = "INT_IsFullscreenHwnd checks per-monitor dimensions"
        Patterns = @("INT_IsFullscreenHwnd", "Win_GetMonitorBoundsFromHwnd")
    },
    @{
        Id       = "bypass_hotkey_toggle"
        File     = "gui\gui_interceptor.ahk"
        Desc     = "INT_SetBypassMode toggles Tab hotkey On/Off"
        Patterns = @('Hotkey("$*Tab", "Off")', 'Hotkey("$*Tab", "On")')
    },
    @{
        Id       = "bypass_eval_all_states"
        File     = "gui\gui_main.ahk"
        Function = "_GUI_OnProducerRevChanged"
        Desc     = "Bypass evaluation runs in all GUI states, not just ACTIVE (issue #91)"
        Patterns = @("INT_SetBypassMode(shouldBypass)", "INT_ShouldBypassWindow(fgHwnd)")
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
        Id       = "path15_tracked_hwnd"
        File     = "shared\window_list.ahk"
        Desc     = "Path 1.5 uses tracked MRU hwnd for direct search with invariant check"
        Regex    = $true
        Patterns = @('gWS_MRUBumpedHwnd', 'lastActivatedTick\s*<\s*sortedRecs')
    },
    @{
        Id       = "ghost_window_detection"
        File     = "shared\window_list.ahk"
        Desc     = "ValidateExistence detects ghost windows via visibility+cloaked+minimized checks"
        Function = "WL_ValidateExistence"
        Patterns = @("IsWindowVisible", "DwmGetWindowAttribute", "IsIconic")
    },
    @{
        Id       = "reveal_both_overlay_gate"
        File     = "gui\gui_paint.ahk"
        Desc     = "_GUI_RevealBoth gates on gGUI_OverlayVisible before showing windows"
        Function = "_GUI_RevealBoth"
        Patterns = @("!gGUI_OverlayVisible")
    },
    @{
        Id       = "event_handler_dump_guard"
        File     = "gui\gui_state.ahk"
        Desc     = "GUI_OnInterceptorEvent blocks events during gFR_DumpInProgress"
        Function = "GUI_OnInterceptorEvent"
        Patterns = @("gFR_DumpInProgress")
    },
    @{
        Id       = "pump_detect_hidden"
        File     = "pump\enrichment_pump.ahk"
        Desc     = "EnrichmentPump enables DetectHiddenWindows for cloaked window resolution"
        Patterns = @("DetectHiddenWindows(true)")
    },
    # --- Callback wiring order: SetCallbacks must precede Start/Init consumers ---
    @{
        Id       = "wl_setcallbacks_before_init"
        File     = "gui\gui_main.ahk"
        Desc     = "WL_SetCallbacks() called before Stats_Init (data layer wired before consumers)"
        Regex    = $true
        Patterns = @("WL_SetCallbacks\([\s\S]*?Stats_Init\(\)")
    },
    @{
        Id       = "stats_setcallbacks_before_init"
        File     = "gui\gui_main.ahk"
        Desc     = "Stats_SetCallbacks() called before Stats_Init() (logging wired before use)"
        Regex    = $true
        Patterns = @("Stats_SetCallbacks\([\s\S]*?Stats_Init\(\)")
    },
    @{
        Id       = "iconpump_setcallbacks_before_start"
        File     = "gui\gui_main.ahk"
        Desc     = "IconPump_SetCallbacks() called before IconPump_Start() (callbacks wired before timer)"
        Regex    = $true
        Patterns = @("IconPump_SetCallbacks\([\s\S]*?IconPump_Start\(\)")
    },
    @{
        Id       = "procpump_setcallbacks_before_start"
        File     = "gui\gui_main.ahk"
        Desc     = "ProcPump_SetCallbacks() called before ProcPump_Start() (callbacks wired before timer)"
        Regex    = $true
        Patterns = @("ProcPump_SetCallbacks\([\s\S]*?ProcPump_Start\(\)")
    },
    # --- Display list mutation safety: cosmetic patching must not touch structural fields ---
    @{
        Id          = "cosmetic_patch_safety"
        File        = "gui\gui_data.ahk"
        Function    = "GUI_PatchCosmeticUpdates"
        Desc        = "GUI_PatchCosmeticUpdates only patches cosmetic fields, never structural"
        NotPresent  = @(".z :=", ".isVisible :=", ".class :=", "item.hwnd :=", "WL_BeginScan", "WL_EndScan")
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
    (Join-Path $SourceDir "core\komorebi_sub.ahk"),
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
    @{ Path = (Join-Path $SourceDir "core\komorebi_sub.ahk"); Prefix = '_KSub' },
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

# Pre-filter: compiled regex matching any v1 pattern keyword (skips modern AHK v2 files)
$v1PreFilter = [regex]::new('(?:Func\s*\(|%\w+%|IfEqual|IfNotEqual|IfGreater|IfLess|IfInString|IfNotInString|StringLeft|StringRight|StringMid|StringLen|StringReplace|StringGetPos|StringLower|StringUpper|StringTrimLeft|StringTrimRight|EnvAdd|EnvSub|EnvMult|EnvDiv|SetEnv|Transform)', 'Compiled')

foreach ($file in $allFiles) {
    # Skip files that can't contain any v1 patterns
    if (-not $v1PreFilter.IsMatch($fileCacheText[$file.FullName])) { continue }

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
# Sub-check 5: display_fields
# Verify DISPLAY_FIELDS and _WS_ToItem stay in sync
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$storeRelPath = "shared\window_list.ahk"
$storeFullPath = if ($relToFull.ContainsKey($storeRelPath)) { $relToFull[$storeRelPath] } else { $null }

if ($null -ne $storeFullPath -and $fileCache.ContainsKey($storeFullPath)) {
    $wsLines = $fileCache[$storeFullPath]
    $wsContent = $fileCacheText[$storeFullPath]

    # Extract DISPLAY_FIELDS
    $projFieldNames = [System.Collections.ArrayList]::new()
    if ($wsContent -match '(?s)global\s+DISPLAY_FIELDS\s*:=\s*\[(.*?)\]') {
        $arrayContent = $Matches[1]
        $fieldMatches = [regex]::Matches($arrayContent, '"(\w+)"')
        foreach ($m in $fieldMatches) {
            [void]$projFieldNames.Add($m.Groups[1].Value)
        }
    }

    # Extract _WS_ToItem return object keys
    $toItemKeys = [System.Collections.ArrayList]::new()
    $funcStartIdx = -1
    for ($wi = 0; $wi -lt $wsLines.Count; $wi++) {
        if ($wsLines[$wi] -match '^\s*_WS_ToItem\s*\(') {
            $funcStartIdx = $wi
            break
        }
    }

    if ($funcStartIdx -ge 0) {
        $funcBody = [System.Text.StringBuilder]::new()
        $pfDepth = 0; $pfStarted = $false
        for ($wi = $funcStartIdx; $wi -lt $wsLines.Count; $wi++) {
            $wLine = $wsLines[$wi]
            [void]$funcBody.AppendLine($wLine)
            foreach ($c in $wLine.ToCharArray()) {
                if ($c -eq '{') { $pfDepth++; $pfStarted = $true }
                elseif ($c -eq '}') { $pfDepth-- }
            }
            if ($pfStarted -and $pfDepth -le 0) { break }
        }
        $funcText = $funcBody.ToString()

        $keyMatches = [regex]::Matches($funcText, '(?m)^\s*(\w+)\s*:\s*rec\.')
        foreach ($m in $keyMatches) {
            [void]$toItemKeys.Add($m.Groups[1].Value)
        }
        $returnLineMatch = [regex]::Match($funcText, 'return\s*\{\s*(\w+)\s*:')
        if ($returnLineMatch.Success) {
            $firstKey = $returnLineMatch.Groups[1].Value
            if ($firstKey -notin $toItemKeys) {
                [void]$toItemKeys.Add($firstKey)
            }
        }
    }

    # Compare (excluding 'hwnd')
    if ($projFieldNames.Count -eq 0) {
        $anyFailed = $true
        [void]$failOutput.AppendLine("")
        [void]$failOutput.AppendLine("  FAIL: DISPLAY_FIELDS array not found or empty in window_list.ahk")
    } elseif ($toItemKeys.Count -eq 0) {
        $anyFailed = $true
        [void]$failOutput.AppendLine("")
        [void]$failOutput.AppendLine("  FAIL: Could not extract keys from _WS_ToItem return object")
    } else {
        $projSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($f in $projFieldNames) { [void]$projSet.Add($f) }

        $toItemSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($k in $toItemKeys) {
            if ($k -ne 'hwnd') { [void]$toItemSet.Add($k) }
        }

        $inProjNotToItem = [System.Collections.ArrayList]::new()
        foreach ($f in $projFieldNames) {
            if (-not $toItemSet.Contains($f)) { [void]$inProjNotToItem.Add($f) }
        }

        $inToItemNotProj = [System.Collections.ArrayList]::new()
        foreach ($k in $toItemKeys) {
            if ($k -ne 'hwnd' -and -not $projSet.Contains($k)) { [void]$inToItemNotProj.Add($k) }
        }

        if ($inProjNotToItem.Count -gt 0 -or $inToItemNotProj.Count -gt 0) {
            $anyFailed = $true
            [void]$failOutput.AppendLine("")
            [void]$failOutput.AppendLine("  FAIL: DISPLAY_FIELDS/_WS_ToItem mismatch:")
            if ($inProjNotToItem.Count -gt 0) {
                [void]$failOutput.AppendLine("    In DISPLAY_FIELDS but not _WS_ToItem: $($inProjNotToItem -join ', ')")
            }
            if ($inToItemNotProj.Count -gt 0) {
                [void]$failOutput.AppendLine("    In _WS_ToItem but not DISPLAY_FIELDS: $($inToItemNotProj -join ', ')")
            }
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_display_fields"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 5b: viewer_columns
# Verify viewer columns (gViewer_ColFields, gViewer_Columns, _Viewer_BuildRowArgs)
# stay in sync with DISPLAY_FIELDS from window_list.ahk
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$viewerRelPath = "viewer\viewer.ahk"
$viewerFullPath = if ($relToFull.ContainsKey($viewerRelPath)) { $relToFull[$viewerRelPath] } else { $null }

if ($null -ne $viewerFullPath -and $fileCache.ContainsKey($viewerFullPath) -and
    $null -ne $storeFullPath -and $fileCacheText.ContainsKey($storeFullPath)) {

    $viewerContent = $fileCacheText[$viewerFullPath]
    $viewerLines = $fileCache[$viewerFullPath]
    $wsContentVC = $fileCacheText[$storeFullPath]

    # --- Parse gViewer_Columns ---
    $viewerHeaders = [System.Collections.ArrayList]::new()
    if ($viewerContent -match 'global\s+gViewer_Columns\s*:=\s*\[(.*?)\]') {
        foreach ($m in [regex]::Matches($Matches[1], '"(\w+)"')) {
            [void]$viewerHeaders.Add($m.Groups[1].Value)
        }
    }

    # --- Parse gViewer_ColFields ---
    $viewerColFields = [System.Collections.ArrayList]::new()
    if ($viewerContent -match 'global\s+gViewer_ColFields\s*:=\s*\[(.*?)\]') {
        foreach ($m in [regex]::Matches($Matches[1], '"(\w+)"')) {
            [void]$viewerColFields.Add($m.Groups[1].Value)
        }
    }

    # --- Parse DISPLAY_FIELDS from store ---
    $displayFields = [System.Collections.ArrayList]::new()
    if ($wsContentVC -match '(?s)global\s+DISPLAY_FIELDS\s*:=\s*\[(.*?)\]') {
        foreach ($m in [regex]::Matches($Matches[1], '"(\w+)"')) {
            [void]$displayFields.Add($m.Groups[1].Value)
        }
    }

    # --- Parse _Viewer_BuildRowArgs field references ---
    $buildRowFields = [System.Collections.Generic.HashSet[string]]::new()
    $brFuncStart = -1
    for ($vi = 0; $vi -lt $viewerLines.Count; $vi++) {
        if ($viewerLines[$vi] -match '^\s*_Viewer_BuildRowArgs\s*\(') {
            $brFuncStart = $vi; break
        }
    }
    if ($brFuncStart -ge 0) {
        $brBody = [System.Text.StringBuilder]::new()
        $brDepth = 0; $brStarted = $false
        for ($vi = $brFuncStart; $vi -lt $viewerLines.Count; $vi++) {
            $brLine = $viewerLines[$vi]
            [void]$brBody.AppendLine($brLine)
            foreach ($c in $brLine.ToCharArray()) {
                if ($c -eq '{') { $brDepth++; $brStarted = $true }
                elseif ($c -eq '}') { $brDepth-- }
            }
            if ($brStarted -and $brDepth -le 0) { break }
        }
        $brText = $brBody.ToString()
        foreach ($m in [regex]::Matches($brText, '_Viewer_Get\s*\(\s*\w+\s*,\s*"(\w+)"')) {
            [void]$buildRowFields.Add($m.Groups[1].Value)
        }
    }

    # --- Fields the viewer intentionally does not display ---
    # workspaceId: internal komorebi ID (viewer shows workspaceName)
    # monitorHandle: raw HMONITOR (viewer shows monitorLabel)
    $viewerExcludedFields = [System.Collections.Generic.HashSet[string]]::new()
    [void]$viewerExcludedFields.Add("workspaceId")
    [void]$viewerExcludedFields.Add("monitorHandle")

    # --- Validate ---
    $vcFailed = $false

    # 1. Header/field array length match
    if ($viewerHeaders.Count -gt 0 -and $viewerColFields.Count -gt 0 -and $viewerHeaders.Count -ne $viewerColFields.Count) {
        $vcFailed = $true
        [void]$failOutput.AppendLine("")
        [void]$failOutput.AppendLine("  FAIL: gViewer_Columns ($($viewerHeaders.Count) headers) and gViewer_ColFields ($($viewerColFields.Count) fields) have different lengths")
    }

    # 2. Every DISPLAY_FIELDS entry (minus excluded) must appear in gViewer_ColFields
    if ($displayFields.Count -gt 0 -and $viewerColFields.Count -gt 0) {
        $colFieldSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($f in $viewerColFields) { [void]$colFieldSet.Add($f) }

        $missingInViewer = [System.Collections.ArrayList]::new()
        foreach ($f in $displayFields) {
            if (-not $viewerExcludedFields.Contains($f) -and -not $colFieldSet.Contains($f)) {
                [void]$missingInViewer.Add($f)
            }
        }
        if ($missingInViewer.Count -gt 0) {
            $vcFailed = $true
            [void]$failOutput.AppendLine("")
            [void]$failOutput.AppendLine("  FAIL: DISPLAY_FIELDS has fields not shown in viewer gViewer_ColFields: $($missingInViewer -join ', ')")
            [void]$failOutput.AppendLine("        Add column to viewer or add to `$viewerExcludedFields in check_batch_patterns.ps1")
        }
    }

    # 3. Every gViewer_ColFields entry (minus hwnd) must be rendered in _Viewer_BuildRowArgs
    if ($viewerColFields.Count -gt 0 -and $buildRowFields.Count -gt 0) {
        $missingInBuildRow = [System.Collections.ArrayList]::new()
        foreach ($f in $viewerColFields) {
            if ($f -ne "hwnd" -and -not $buildRowFields.Contains($f)) {
                [void]$missingInBuildRow.Add($f)
            }
        }
        if ($missingInBuildRow.Count -gt 0) {
            $vcFailed = $true
            [void]$failOutput.AppendLine("")
            [void]$failOutput.AppendLine("  FAIL: gViewer_ColFields has fields not rendered in _Viewer_BuildRowArgs: $($missingInBuildRow -join ', ')")
        }
    }

    if ($vcFailed) { $anyFailed = $true }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_viewer_columns"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 6: map_dot_access
# Detects .property access on variables assigned from Map-creating
# expressions (Map(), cJSON.Parse(), JSON.Parse()). In AHK v2,
# Maps use ["key"] indexing; .property access throws MethodError.
# Also propagates Map type through bracket access:
#   result := cJSON.Parse(json)  → result tracked
#   data := result["nested"]     → data tracked (bracket-derived)
# Origin-aware: only flags variables traced to Map constructors,
# NOT plain Objects from gWS_Store or _WS_NewRecord().
# CLAUDE.md: "Store expects Map records: use rec["key"] not rec.key"
# Suppress: ; lint-ignore: map-dot-access
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$mdaIssues = [System.Collections.ArrayList]::new()
$MDA_SUPPRESSION = 'lint-ignore: map-dot-access'

# Allowed Map method/property names (not field access)
$MDA_ALLOWED_METHODS = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($method in @('Has', 'Get', 'Set', 'Delete', 'Clear', 'Clone',
                       'Count', 'Capacity', 'Default', 'CaseSense',
                       '__Class', '__New', '__Enum', '__Item',
                       'OwnProps', 'HasOwnProp', 'DefineProp',
                       'GetOwnPropDesc', 'HasProp', 'HasMethod',
                       'GetMethod', 'Ptr', 'Base', 'Length',
                       'Push', 'Pop', 'InsertAt', 'RemoveAt')) {
    [void]$MDA_ALLOWED_METHODS.Add($method)
}

# Regex to detect Map-creating assignments: varName := Map( | cJSON.Parse( | JSON.Parse(
$mdaMapAssignRegex = [regex]::new(
    '^\s*(\w+)\s*:=\s*(?:Map\s*\(|cJSON\.Parse\s*\(|JSON\.Parse\s*\()',
    'Compiled'
)

# Regex to detect function start (resets Map variable scope)
$mdaFuncStartRegex = [regex]::new(
    '^\s*(?:static\s+)?[A-Za-z_]\w*\s*\([^)]*\)\s*\{?',
    'Compiled'
)

# Only check core producer and IPC files (where Maps are the primary data structure)
$mdaStoreFiles = @($allFiles | Where-Object {
    $_.FullName -like "*\core\*" -or $_.FullName -like "*\shared\ipc*"
})

foreach ($file in $mdaStoreFiles) {
    $lines = $fileCache[$file.FullName]
    $text = $fileCacheText[$file.FullName]

    # Pre-filter: does this file create any Maps?
    if (-not ($text.Contains('Map(') -or $text.Contains('cJSON.Parse(') -or $text.Contains('JSON.Parse('))) {
        continue
    }

    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $inBlockComment = $false
    # Track Map variables per function scope (reset on new function definition)
    $mapVarsInScope = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]

        if ($inBlockComment) {
            if ($raw -match '\*/') { $inBlockComment = $false }
            continue
        }
        if ($raw -match '^\s*/\*') { $inBlockComment = $true; continue }
        if ($raw -match '^\s*;') { continue }
        if ($raw.Contains($MDA_SUPPRESSION)) { continue }

        $cleaned = BP_Clean-Line $raw
        if ($cleaned -eq '') { continue }

        # Reset Map tracking on new function definition
        if ($mdaFuncStartRegex.IsMatch($cleaned)) {
            $mapVarsInScope.Clear()
        }

        # Track Map-creating assignments
        $assignMatch = $mdaMapAssignRegex.Match($cleaned)
        if ($assignMatch.Success) {
            [void]$mapVarsInScope.Add($assignMatch.Groups[1].Value)
        }

        # Propagate Map type through bracket access: child := trackedMap["key"]
        # The indexed element of a parsed JSON Map is typically another Map.
        if ($mapVarsInScope.Count -gt 0) {
            foreach ($parentVar in @($mapVarsInScope)) {
                $bracketPat = '^\s*(\w+)\s*:=\s*' + [regex]::Escape($parentVar) + '\s*\['
                if ($cleaned -match $bracketPat) {
                    $derived = $Matches[1]
                    if ($derived -ne $parentVar) {
                        [void]$mapVarsInScope.Add($derived)
                    }
                }
            }
        }

        # Only check dot access if we have tracked Map variables
        if ($mapVarsInScope.Count -eq 0) { continue }

        # Check for dot access on tracked Map variables
        foreach ($mapVar in @($mapVarsInScope)) {
            $dotPrefix = "$mapVar."
            if ($cleaned.IndexOf($dotPrefix, [System.StringComparison]::Ordinal) -lt 0) { continue }

            $escapedVar = [regex]::Escape($mapVar)
            $dotMatches = [regex]::Matches($cleaned, "\b$escapedVar\.(\w+)")
            foreach ($m in $dotMatches) {
                $fieldName = $m.Groups[1].Value

                # Skip method calls (followed by parenthesis)
                $afterEnd = $m.Index + $m.Length
                if ($afterEnd -lt $cleaned.Length -and $cleaned[$afterEnd] -eq '(') { continue }

                # Skip allowed methods/properties
                if ($MDA_ALLOWED_METHODS.Contains($fieldName)) { continue }

                [void]$mdaIssues.Add([PSCustomObject]@{
                    File  = $relPath
                    Line  = $i + 1
                    Var   = $mapVar
                    Field = $fieldName
                    Code  = $raw.Trim()
                })
            }
        }
    }
}

if ($mdaIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($mdaIssues.Count) Map dot-access issue(s) found.")
    [void]$failOutput.AppendLine('  Maps from Map()/cJSON.Parse() use ["key"] not .key in AHK v2.')
    [void]$failOutput.AppendLine("  .property access on Maps throws MethodError.")
    [void]$failOutput.AppendLine('  Fix: use var["fieldName"] syntax, or suppress with ''; lint-ignore: map-dot-access''.')
    $grouped = $mdaIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            $dotForm = "$($issue.Var).$($issue.Field)"
            $bracketForm = $issue.Var + '["' + $issue.Field + '"]'
            [void]$failOutput.AppendLine("      Line $($issue.Line): $dotForm - use $bracketForm")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_map_dot_access"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 7: dirty_tracking_contract
# Any function in window_list.ahk that bumps gWS_Rev AND modifies
# display-visible fields must also reference gWS_DirtyHwnds.
# Catches "forgot to add dirty tracking" bugs at the static level.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$dtRelPath = "shared\window_list.ahk"
$dtFullPath = if ($relToFull.ContainsKey($dtRelPath)) { $relToFull[$dtRelPath] } else { $null }

if ($null -ne $dtFullPath -and $fileCacheText.ContainsKey($dtFullPath)) {
    $dtContent = $fileCacheText[$dtFullPath]

    # Extract DISPLAY_FIELDS for field matching
    $dtDisplayFields = [System.Collections.Generic.HashSet[string]]::new()
    if ($dtContent -match '(?s)global\s+DISPLAY_FIELDS\s*:=\s*\[(.*?)\]') {
        $dfArrayContent = $Matches[1]
        foreach ($m in [regex]::Matches($dfArrayContent, '"(\w+)"')) {
            [void]$dtDisplayFields.Add($m.Groups[1].Value)
        }
    }

    # Exempt functions (canonical implementations, bulk ops, read-only)
    $dtExempt = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($name in @("_WS_ApplyPatch", "_WS_MarkDirty", "WL_Init", "WL_BeginScan",
                         "WL_EndScan", "WL_GetDisplayList", "_WS_BumpRev",
                         "WL_SetCurrentWorkspace", "WL_BatchUpdateFields",
                         "_WS_ToItem", "_WS_NewRecord", "WS_SnapshotMapKeys",
                         "WL_EnqueueForZ", "WL_ClearZQueue", "_WL_GetRev",
                         "_WS_InsertionSort", "_WS_CmpMRU", "_WS_CmpZ",
                         "_WS_CmpTitle", "_WS_CmpProcessName", "_WS_GetOpt")) {
        [void]$dtExempt.Add($name)
    }

    # Extract all function bodies from window_list.ahk
    $dtIssues = @()
    $dtFuncRegex = [regex]::new('(?m)^[ \t]*(?:static\s+)?([A-Za-z_]\w*)\s*\([^)]*\)\s*\{', 'Compiled')
    $dtFuncMatches = $dtFuncRegex.Matches($dtContent)

    foreach ($fm in $dtFuncMatches) {
        $funcName = $fm.Groups[1].Value
        if ($dtExempt.Contains($funcName)) { continue }

        $body = BP_Extract-FunctionBody $dtContent $funcName
        if ($null -eq $body) { continue }

        # Check: does this function bump rev? (calls _WS_BumpRev or _WS_MarkDirty or directly modifies gWS_Rev)
        $bumpsRev = $body.Contains("_WS_BumpRev") -or $body.Contains("_WS_MarkDirty") -or ($body -match 'gWS_Rev\s*(\+\+|\+=|:=)')
        if (-not $bumpsRev) { continue }

        # Check: does this function modify any display-visible field on a store record?
        $touchesDisplayField = $false
        foreach ($field in $dtDisplayFields) {
            # Match rec.field := or rec["field"] := patterns
            if ($body -match "\.\s*$field\s*:=" -or $body -match "\[`"$field`"\]\s*:=") {
                $touchesDisplayField = $true
                break
            }
        }
        if (-not $touchesDisplayField) { continue }

        # This function bumps rev AND writes display fields — must also touch gWS_DirtyHwnds
        # Require actual usage: gWS_DirtyHwnds[ (assignment) or _WS_ApplyPatch (delegates dirty tracking)
        # A mere string mention (e.g., in a comment) is not sufficient.
        $hasDirtyTracking = ($body -match 'gWS_DirtyHwnds\[') -or ($body.Contains('_WS_ApplyPatch'))
        if (-not $hasDirtyTracking) {
            $dtIssues += "${funcName}: bumps rev and modifies display fields but does not mark gWS_DirtyHwnds"
        }
    }

    if ($dtIssues.Count -gt 0) {
        $anyFailed = $true
        [void]$failOutput.AppendLine("")
        [void]$failOutput.AppendLine("  FAIL: $($dtIssues.Count) dirty-tracking contract violation(s) in window_list.ahk")
        [void]$failOutput.AppendLine("  Functions that bump gWS_Rev and modify display fields must also mark gWS_DirtyHwnds.")
        foreach ($issue in $dtIssues) {
            [void]$failOutput.AppendLine("    $issue")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_dirty_tracking"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 7b: direct_record_mutation
# Post-refactor guard: files outside window_list.ahk must NOT write
# to properties of store record references obtained via gWS_Store[hwnd].
# These references are live objects — writing bypasses dirty tracking,
# Critical sections, and rev bumping. Use WL_UpdateFields/WL_BatchUpdateFields.
# Suppress: ; lint-ignore: direct-record-mutation
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$drmIssues = [System.Collections.ArrayList]::new()
$DRM_SUPPRESSION = 'lint-ignore: direct-record-mutation'

# Regex: variable assigned from gWS_Store[...] or gWS_Store.Get(...)
$drmStoreRefRegex = [regex]::new(
    '^\s*(\w+)\s*:=\s*gWS_Store(?:\[|\.\s*Get\s*\()',
    'Compiled'
)
# Regex: detected function start (resets tracked variable scope)
$drmFuncStartRegex = [regex]::new(
    '^\s*(?:static\s+)?[A-Za-z_]\w*\s*\([^)]*\)\s*\{?',
    'Compiled'
)

# Only check files outside window_list.ahk that reference gWS_Store
$drmFiles = @($allFiles | Where-Object {
    $_.Name -ne 'window_list.ahk' -and $fileCacheText[$_.FullName].Contains('gWS_Store')
})

foreach ($file in $drmFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName.Replace("$projectRoot\", '')
    $inBlockComment = $false
    # Track variables holding store record references per function scope
    $storeRefsInScope = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]

        if ($inBlockComment) {
            if ($raw -match '\*/') { $inBlockComment = $false }
            continue
        }
        if ($raw -match '^\s*/\*') { $inBlockComment = $true; continue }
        if ($raw -match '^\s*;') { continue }
        if ($raw.Contains($DRM_SUPPRESSION)) { continue }

        $cleaned = BP_Clean-Line $raw
        if ($cleaned -eq '') { continue }

        # Reset tracking on new function definition
        if ($drmFuncStartRegex.IsMatch($cleaned)) {
            $storeRefsInScope.Clear()
        }

        # Track store record reference assignments
        $refMatch = $drmStoreRefRegex.Match($cleaned)
        if ($refMatch.Success) {
            [void]$storeRefsInScope.Add($refMatch.Groups[1].Value)
        }

        # Check for property writes on tracked store references
        if ($storeRefsInScope.Count -eq 0) { continue }

        foreach ($refVar in @($storeRefsInScope)) {
            # Match refVar.anyProp := (property assignment, not comparison or read)
            $escapedVar = [regex]::Escape($refVar)
            if ($cleaned -match "\b$escapedVar\.(\w+)\s*:=") {
                $fieldName = $Matches[1]
                [void]$drmIssues.Add([PSCustomObject]@{
                    File  = $relPath
                    Line  = $i + 1
                    Var   = $refVar
                    Field = $fieldName
                    Code  = $raw.Trim()
                })
            }
        }
    }
}

if ($drmIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($drmIssues.Count) direct store record mutation(s) found outside window_list.ahk.")
    [void]$failOutput.AppendLine("  Store records from gWS_Store[hwnd] are live references -- writing to their properties")
    [void]$failOutput.AppendLine("  bypasses dirty tracking, Critical sections, and rev bumping.")
    [void]$failOutput.AppendLine('  Fix: use WL_UpdateFields() or WL_BatchUpdateFields() instead.')
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: direct-record-mutation' on the offending line.")
    $grouped = $drmIssues | Group-Object File
    foreach ($group in $grouped | Sort-Object Name) {
        [void]$failOutput.AppendLine("    $($group.Name):")
        foreach ($issue in $group.Group | Sort-Object Line) {
            [void]$failOutput.AppendLine("      Line $($issue.Line): $($issue.Var).$($issue.Field) := ... -- use WL_UpdateFields()")
        }
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_direct_record_mutation"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 8: fr_guard
# Every FR_Record() call must be guarded by if (gFR_Enabled).
# Flight recorder is near-zero cost when enabled, but when disabled
# the caller-side guard eliminates function call dispatch overhead
# in hot paths (keyboard hooks, state machine, WinEvent callbacks).
# Suppress: ; lint-ignore: fr-guard
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frIssues = [System.Collections.ArrayList]::new()

foreach ($file in $allFiles) {
    # Skip the flight recorder itself (FR_Record definition + FR_Init call after gFR_Enabled := true)
    if ($file.Name -eq 'gui_flight_recorder.ahk') { continue }

    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName
    if ($relPath.StartsWith($SourceDir)) {
        $relPath = $relPath.Substring($SourceDir.Length).TrimStart('\', '/')
    }

    for ($li = 0; $li -lt $lines.Count; $li++) {
        $line = $lines[$li]

        # Skip comments
        $trimmed = $line.TrimStart()
        if ($trimmed.Length -eq 0 -or $trimmed[0] -eq ';') { continue }

        # Check for FR_Record( on this line
        if ($line.IndexOf('FR_Record(', [System.StringComparison]::Ordinal) -lt 0) { continue }

        # Strip string literals and trailing comments to avoid false positives
        $cleaned = BP_Clean-Line $line
        if ($cleaned.IndexOf('FR_Record(', [System.StringComparison]::Ordinal) -lt 0) { continue }

        # Check for lint-ignore on this line or the preceding line
        $suppressed = $false
        if ($line.IndexOf('lint-ignore:', [System.StringComparison]::Ordinal) -ge 0 -and $line -match 'lint-ignore:\s*fr-guard') {
            $suppressed = $true
        }
        if (-not $suppressed -and $li -gt 0) {
            $prevLine = $lines[$li - 1]
            if ($prevLine.IndexOf('lint-ignore:', [System.StringComparison]::Ordinal) -ge 0 -and $prevLine -match 'lint-ignore:\s*fr-guard') {
                $suppressed = $true
            }
        }
        if ($suppressed) { continue }

        # Check if the preceding non-blank, non-comment line contains 'if (gFR_Enabled)'
        # or if FR_Record is on the same line after 'if (gFR_Enabled)'
        $guarded = $false

        # Same-line guard: if (gFR_Enabled) FR_Record(...)
        if ($cleaned -match 'if\s*\(\s*gFR_Enabled\s*\)') {
            $guarded = $true
        }

        # Previous-line guard: if (gFR_Enabled)\n    FR_Record(...)
        if (-not $guarded) {
            for ($pi = $li - 1; $pi -ge 0 -and $pi -ge ($li - 3); $pi--) {
                $prevLine = $lines[$pi].TrimStart()
                if ($prevLine.Length -eq 0 -or $prevLine[0] -eq ';') { continue }
                if ($prevLine -match '^\s*if\s*\(\s*gFR_Enabled\s*\)') {
                    $guarded = $true
                }
                break  # Stop at first non-blank, non-comment line
            }
        }

        if (-not $guarded) {
            $lineNum = $li + 1
            $snippet = $trimmed.Substring(0, [Math]::Min(60, $trimmed.Length))
            [void]$frIssues.Add("${relPath}:${lineNum}: $snippet")
        }
    }
}

if ($frIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($frIssues.Count) ungated FR_Record() call(s)")
    [void]$failOutput.AppendLine("  Every FR_Record() call must be guarded by 'if (gFR_Enabled)' on the preceding line.")
    [void]$failOutput.AppendLine("  This eliminates function dispatch overhead when flight recorder is disabled.")
    foreach ($issue in $frIssues) {
        [void]$failOutput.AppendLine("    $issue")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_fr_guard"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 9: copydata_contract
# Validates WM_COPYDATA TABBY_CMD_* constants have symmetric
# sender (NumPut) and handler (dwData = TABBY_CMD_*) coverage.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$cdIssues = [System.Collections.ArrayList]::new()

# Collect all TABBY_CMD_* definitions
$cmdDefs = [System.Collections.Generic.HashSet[string]]::new()
foreach ($path in $fileCacheText.Keys) {
    $text = $fileCacheText[$path]
    $defMatches = [regex]::Matches($text, 'global\s+(TABBY_CMD_\w+)\s*:=')
    foreach ($m in $defMatches) {
        [void]$cmdDefs.Add($m.Groups[1].Value)
    }
}

# Collect send sites: NumPut("uptr", TABBY_CMD_*, ...) or relay functions like Launcher_RelayToGui(TABBY_CMD_*)
$cmdSent = [System.Collections.Generic.HashSet[string]]::new()
foreach ($path in $fileCacheText.Keys) {
    $text = $fileCacheText[$path]
    $sendMatches = [regex]::Matches($text, 'NumPut\([^)]*?(TABBY_CMD_\w+)')
    foreach ($m in $sendMatches) {
        [void]$cmdSent.Add($m.Groups[1].Value)
    }
    # Indirect sends via relay/helper functions that wrap WM_COPYDATA sending
    $relayMatches = [regex]::Matches($text, 'Launcher_RelayToGui\(\s*(TABBY_CMD_\w+)')
    foreach ($m in $relayMatches) {
        [void]$cmdSent.Add($m.Groups[1].Value)
    }
    $helperMatches = [regex]::Matches($text, 'IPC_SendWmCopyData\w*\([^,]*,\s*(TABBY_CMD_\w+)')
    foreach ($m in $helperMatches) {
        [void]$cmdSent.Add($m.Groups[1].Value)
    }
}

# Collect handler sites: dwData = TABBY_CMD_*
$cmdHandled = [System.Collections.Generic.HashSet[string]]::new()
foreach ($path in $fileCacheText.Keys) {
    $text = $fileCacheText[$path]
    $handleMatches = [regex]::Matches($text, 'dwData\s*=\s*(TABBY_CMD_\w+)')
    foreach ($m in $handleMatches) {
        [void]$cmdHandled.Add($m.Groups[1].Value)
    }
}

# Check: defined but never sent (dead command)
foreach ($cmd in $cmdDefs) {
    if (-not $cmdSent.Contains($cmd) -and -not $cmdHandled.Contains($cmd)) {
        [void]$cdIssues.Add("${cmd}: defined but never sent or handled (dead command)")
    }
}

# Check: sent but never handled (silent message drop)
foreach ($cmd in $cmdSent) {
    if (-not $cmdHandled.Contains($cmd)) {
        [void]$cdIssues.Add("${cmd}: sent via NumPut but no handler checks dwData = ${cmd} (silent drop)")
    }
}

# Check: handled but never sent (dead handler)
foreach ($cmd in $cmdHandled) {
    if (-not $cmdSent.Contains($cmd)) {
        [void]$cdIssues.Add("${cmd}: handler exists (dwData = ${cmd}) but never sent via NumPut (dead handler)")
    }
}

if ($cdIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($cdIssues.Count) WM_COPYDATA contract issue(s) found.")
    [void]$failOutput.AppendLine("  Every TABBY_CMD_* must have both a sender (NumPut) and a handler (dwData = CMD).")
    foreach ($issue in $cdIssues) {
        [void]$failOutput.AppendLine("    $issue")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_copydata_contract"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 10: scan_pairing
# Every WL_BeginScan() call must be inside a try block with
# WL_EndScan() in the corresponding finally clause.
# If EndScan never runs (exception, early return), gWS_ScanId
# stays incremented and every window fails the lastSeenScanId
# check — total window list corruption.
# Suppress: ; lint-ignore: scan-pairing
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$scanIssues = [System.Collections.ArrayList]::new()
$scanFuncRegex = [regex]::new('(?m)^[ \t]*(?:static\s+)?([A-Za-z_]\w*)\s*\([^)]*\)\s*\{', 'Compiled')
$scanKeywords = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('if', 'while', 'for', 'loop', 'switch', 'catch', 'try', 'else'),
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($file in $allFiles) {
    $text = $fileCacheText[$file.FullName]
    if ($text.IndexOf('WL_BeginScan()', [System.StringComparison]::Ordinal) -lt 0) { continue }

    $relPath = $file.FullName
    if ($relPath.StartsWith($SourceDir)) {
        $relPath = $relPath.Substring($SourceDir.Length).TrimStart('\', '/')
    }

    # Per-function scan: find functions that call WL_BeginScan() and verify pairing
    $funcMatches = $scanFuncRegex.Matches($text)
    foreach ($fm in $funcMatches) {
        $funcName = $fm.Groups[1].Value
        if ($scanKeywords.Contains($funcName)) { continue }
        # Skip the WL_BeginScan definition itself
        if ($funcName -eq 'WL_BeginScan') { continue }

        $body = BP_Extract-FunctionBody $text $funcName
        if ($null -eq $body) { continue }
        if ($body.IndexOf('WL_BeginScan()', [System.StringComparison]::Ordinal) -lt 0) { continue }

        # Check for lint-ignore suppression anywhere in the function body
        if ($body.Contains('lint-ignore: scan-pairing')) { continue }

        # Verify: try keyword before BeginScan, and finally with EndScan after BeginScan
        $beginPos = $body.IndexOf('WL_BeginScan()')
        $hasTryBefore = $body.Substring(0, $beginPos).Contains('try')
        $finallyIdx = $body.IndexOf('finally', $beginPos)
        $hasEndScanInFinally = $false
        if ($finallyIdx -ge 0) {
            $hasEndScanInFinally = $body.IndexOf('WL_EndScan()', $finallyIdx) -ge 0
        }

        if (-not $hasTryBefore -or -not $hasEndScanInFinally) {
            # Find approximate line number for the error message
            $funcStartLine = ($text.Substring(0, $fm.Index) -split "`n").Count
            $bodyBefore = $body.Substring(0, $beginPos)
            $lineOffset = ($bodyBefore -split "`n").Count
            $approxLine = $funcStartLine + $lineOffset
            [void]$scanIssues.Add("${relPath}:${approxLine}: WL_BeginScan() in ${funcName}() not paired with try { ... } finally { WL_EndScan() }")
        }
    }
}

if ($scanIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($scanIssues.Count) scan-pairing violation(s) found.")
    [void]$failOutput.AppendLine("  Every WL_BeginScan() must be in try { ... } finally { WL_EndScan() }.")
    [void]$failOutput.AppendLine("  Without finally, exceptions leave gWS_ScanId stuck - corrupting the window list.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: scan-pairing' on the WL_BeginScan() line.")
    foreach ($issue in $scanIssues) {
        [void]$failOutput.AppendLine("    $issue")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_scan_pairing"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 11: setcallbacks_wiring
# Every *_SetCallbacks() function definition in a producer module
# must have at least one call site in another file. An unwired
# SetCallbacks means the producer runs but nobody receives results
# (silent data loss, not a crash — hard to detect manually).
# Suppress: ; lint-ignore: setcallbacks-wiring (on the function definition line)
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$scwIssues = [System.Collections.ArrayList]::new()
$SCW_SUPPRESSION = 'lint-ignore: setcallbacks-wiring'

# Phase 1: Find all *_SetCallbacks() function definitions across src/
$scwDefs = @{}  # funcName -> @{ File; Line }

foreach ($file in $allFiles) {
    $lines = $fileCache[$file.FullName]
    $relPath = $file.FullName
    if ($relPath.StartsWith($SourceDir)) {
        $relPath = $relPath.Substring($SourceDir.Length).TrimStart('\', '/')
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        if ($raw -match '^\s*;') { continue }
        if ($raw.Contains($SCW_SUPPRESSION)) { continue }
        # Match function definition: SomeName_SetCallbacks(params) {
        if ($raw -match '^\s*(\w+_SetCallbacks)\s*\([^)]*\)\s*\{?') {
            $funcName = $Matches[1]
            if (-not $scwDefs.ContainsKey($funcName)) {
                $scwDefs[$funcName] = @{ File = $relPath; FullPath = $file.FullName; Line = $i + 1 }
            }
        }
    }
}

# Phase 2: For each definition, search for call sites in OTHER files
foreach ($funcName in @($scwDefs.Keys)) {
    $def = $scwDefs[$funcName]
    $hasExternalCallSite = $false

    foreach ($file in $allFiles) {
        # Skip the file where the function is defined
        if ($file.FullName -eq $def.FullPath) { continue }

        $text = $fileCacheText[$file.FullName]
        if ($text.Contains("$funcName(")) {
            $hasExternalCallSite = $true
            break
        }
    }

    if (-not $hasExternalCallSite) {
        [void]$scwIssues.Add([PSCustomObject]@{
            File = $def.File; Line = $def.Line; Function = $funcName
        })
    }
}

if ($scwIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($scwIssues.Count) *_SetCallbacks() definition(s) with no external call site.")
    [void]$failOutput.AppendLine("  An unwired SetCallbacks means the producer runs but results are silently discarded.")
    [void]$failOutput.AppendLine("  Fix: add a call to the function in the wiring code (typically gui_main.ahk).")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: setcallbacks-wiring' on the function definition line.")
    foreach ($issue in $scwIssues | Sort-Object File, Line) {
        [void]$failOutput.AppendLine("    $($issue.File):$($issue.Line): $($issue.Function)() defined but never called from another file")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_setcallbacks_wiring"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 12: cache_path_invariants
# WL_GetDisplayList has 4 cache paths with dirty-flag guard
# conditions. Each path must clear its dirty flags after rebuild.
# Catches "forgot to clear dirty flag" bugs that cause either
# performance regression (re-entering expensive path) or stale
# display data (wrong path selected).
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$cpiIssues = [System.Collections.ArrayList]::new()

$cpiRelPath = "shared\window_list.ahk"
$cpiFullPath = if ($relToFull.ContainsKey($cpiRelPath)) { $relToFull[$cpiRelPath] } else { $null }

if ($null -ne $cpiFullPath -and $fileCacheText.ContainsKey($cpiFullPath)) {
    $cpiBody = BP_Extract-FunctionBody $fileCacheText[$cpiFullPath] "WL_GetDisplayList"

    if ($null -ne $cpiBody) {
        # Dirty flags that must be managed by the cache system
        $dirtyFlags = @("gWS_SortOrderDirty", "gWS_ContentDirty", "gWS_MRUBumpOnly")

        # Split into lines for line-number reporting
        $cpiLines = $cpiBody -split "`r?`n"

        # --- Invariant 1: Every dirty flag must be cleared (:= false or := 0) somewhere in the function ---
        foreach ($flag in $dirtyFlags) {
            $clearPattern = "${flag}\s*:=\s*(false|0)\b"
            if (-not ($cpiBody -match $clearPattern)) {
                [void]$cpiIssues.Add("${cpiRelPath}: WL_GetDisplayList() never clears ${flag} - cache will never hit for paths guarded by this flag")
            }
        }

        # --- Invariant 2: gWS_DirtyHwnds must be reset (assigned new Map()) somewhere ---
        if (-not ($cpiBody -match 'gWS_DirtyHwnds\s*:=\s*Map\(\)')) {
            [void]$cpiIssues.Add("${cpiRelPath}: WL_GetDisplayList() never resets gWS_DirtyHwnds - stale dirty tracking accumulates")
        }

        # --- Invariant 3: Each cache path that rebuilds data must clear flags AFTER the rebuild ---
        # Detect path markers via cachePath string literals
        $pathMarkers = @(
            @{ Name = "Path 1.5 (MRU)";    Marker = 'cachePath: "mru"';     RequiredClears = @("gWS_SortOrderDirty", "gWS_ContentDirty", "gWS_MRUBumpOnly") }
            @{ Name = "Path 2 (content)";   Marker = 'cachePath: "content"'; RequiredClears = @("gWS_ContentDirty") }
            @{ Name = "Path 3 (full)";      Marker = 'cachePath: "full"';    RequiredClears = @("gWS_SortOrderDirty", "gWS_ContentDirty", "gWS_MRUBumpOnly") }
        )

        foreach ($path in $pathMarkers) {
            $markerIdx = $cpiBody.IndexOf($path.Marker)
            if ($markerIdx -lt 0) {
                [void]$cpiIssues.Add("${cpiRelPath}: WL_GetDisplayList() missing $($path.Name) - expected cachePath marker '$($path.Marker)'")
                continue
            }

            # Extract the section BEFORE this path's result return (the rebuild zone)
            # Look backwards from the marker to find the dirty flag clears
            $sectionBefore = $cpiBody.Substring(0, $markerIdx)

            foreach ($flag in $path.RequiredClears) {
                $clearPattern = "${flag}\s*:=\s*(false|0)\b"
                # The clear must appear in the section leading up to this path's result
                if (-not ($sectionBefore -match $clearPattern)) {
                    [void]$cpiIssues.Add("${cpiRelPath}: WL_GetDisplayList() $($path.Name) does not clear ${flag} before returning - causes re-entry into expensive path")
                }
            }
        }

        # --- Invariant 4: Path 1 (cache hit) must NOT clear any dirty flags ---
        $cacheHitMarkerIdx = $cpiBody.IndexOf('cachePath: "cache"')
        if ($cacheHitMarkerIdx -ge 0) {
            # Section between function start and first cache hit return
            $cacheHitSection = $cpiBody.Substring(0, $cacheHitMarkerIdx)
            # Find where this path starts (look for the Path 1 comment or the first Critical "On")
            # Only check the narrow section for this path (from start to the cache marker)
            foreach ($flag in $dirtyFlags) {
                $clearPattern = "${flag}\s*:=\s*(false|0)\b"
                if ($cacheHitSection -match $clearPattern) {
                    [void]$cpiIssues.Add("${cpiRelPath}: WL_GetDisplayList() Path 1 (cache hit) clears ${flag} - cache hit path should not modify dirty state")
                }
            }
        }
    }
}

if ($cpiIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($cpiIssues.Count) cache-path invariant violation(s) in WL_GetDisplayList().")
    [void]$failOutput.AppendLine("  Each cache path must clear its dirty flags after rebuild to prevent re-entry or stale data.")
    foreach ($issue in $cpiIssues) {
        [void]$failOutput.AppendLine("    $issue")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_cache_path_invariants"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Sub-check 13: numeric_string_comparison
# Detects comparisons between known-numeric variables and
# non-numeric string literals. In AHK v2, if either operand
# is a pure number, the comparison is numeric — so
# `if (hwnd = "sometext")` is always false (0 != NaN).
# This catches silent logic bugs from type mismatch.
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$nscIssues = [System.Collections.ArrayList]::new()

# Known numeric variable name patterns (hwnd, pid, handle-like)
$nscNumericNamePattern = '^(?:h[A-Z]\w*|hwnd|pid|exitCode)$'

# AHK v2 comparison pattern inside conditionals:
#   if (var = "string")   if (var != "string")   if (var == "string")
# Must NOT be preceded by a quote (which would indicate string concatenation)
# The variable must be preceded by ( or && or || or space-after-keyword, NOT by "
# We look for: non-quote-char + word + whitespace + comparison-op + whitespace + "string"
$nscCompPattern = '(?<!["`])\b(\w+)\s+(=|==|!=)\s+"([^"]*)"'
$nscRevPattern = '"([^"]*)"\s+(=|==|!=)\s+(\w+)\b(?!["`])'

foreach ($f in $allFiles) {
    $lines = $fileCache[$f.FullName]
    $relPath = $f.FullName.Substring($SourceDir.Length).TrimStart('\', '/')
    $text = $fileCacheText[$f.FullName]

    # Skip files that don't have conditional comparisons with strings
    if ($text.IndexOf('if ', [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -and
        $text.IndexOf('while ', [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -and
        $text.IndexOf('case ', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $trimmed = $raw.TrimStart()
        if ($trimmed.Length -eq 0 -or $trimmed[0] -eq ';') { continue }
        if ($raw -match ';\s*lint-ignore:\s*numeric-string-comparison') { continue }

        # Only check lines that contain conditional keywords
        # This dramatically reduces false positives from string concatenation
        $isConditional = $trimmed -match '^(?:if|else\s+if|while|until|case)\b' -or $trimmed -match '\?\s*\w'
        if (-not $isConditional) { continue }

        # Strip trailing comments (respecting string boundaries)
        $codePart = $raw
        $inStr = $false
        for ($ci = 0; $ci -lt $codePart.Length; $ci++) {
            $ch = $codePart[$ci]
            if ($ch -eq '"') { $inStr = -not $inStr }
            elseif ($ch -eq ';' -and -not $inStr -and $ci -gt 0 -and $codePart[$ci-1] -match '\s') {
                $codePart = $codePart.Substring(0, $ci); break
            }
        }

        # Pattern: knownNumericVar = "non-numeric-string"
        $compMatches = [regex]::Matches($codePart, $nscCompPattern)
        foreach ($m in $compMatches) {
            $varName = $m.Groups[1].Value
            $strVal = $m.Groups[3].Value

            # Skip if the string is a valid number (including hex)
            if ($strVal -match '^-?\d+(?:\.\d+)?$' -or $strVal -match '^0x[0-9A-Fa-f]+$') { continue }
            # Skip empty string comparisons (common and intentional)
            if ($strVal -eq '') { continue }
            # Skip AHK keywords that look like variables
            # Skip common non-variable keywords
            if ($varName -eq 'not' -or $varName -eq 'and' -or $varName -eq 'or' -or $varName -eq 'is') { continue }

            # Only flag if variable matches known-numeric name pattern
            if ($varName -match $nscNumericNamePattern) {
                [void]$nscIssues.Add("${relPath}:$($i+1): comparing numeric var '$varName' to non-numeric string `"$strVal`" (always false in AHK v2)")
            }
        }

        # Reverse: "non-numeric-string" = knownNumericVar
        $revMatches = [regex]::Matches($codePart, $nscRevPattern)
        foreach ($m in $revMatches) {
            $strVal = $m.Groups[1].Value
            $varName = $m.Groups[3].Value

            if ($strVal -match '^-?\d+(?:\.\d+)?$' -or $strVal -match '^0x[0-9A-Fa-f]+$') { continue }
            if ($strVal -eq '') { continue }
            # Skip common non-variable keywords
            if ($varName -eq 'not' -or $varName -eq 'and' -or $varName -eq 'or' -or $varName -eq 'is') { continue }

            if ($varName -match $nscNumericNamePattern) {
                [void]$nscIssues.Add("${relPath}:$($i+1): comparing non-numeric string `"$strVal`" to numeric var '$varName' (always false in AHK v2)")
            }
        }
    }
}

if ($nscIssues.Count -gt 0) {
    $anyFailed = $true
    [void]$failOutput.AppendLine("")
    [void]$failOutput.AppendLine("  FAIL: $($nscIssues.Count) numeric/string comparison mismatch(es).")
    [void]$failOutput.AppendLine("  AHK v2 compares numerically when either operand is a pure number.")
    [void]$failOutput.AppendLine("  Comparing a numeric variable to a non-numeric string always evaluates to false.")
    [void]$failOutput.AppendLine("  Suppress: add '; lint-ignore: numeric-string-comparison' on the same line.")
    foreach ($issue in $nscIssues) {
        [void]$failOutput.AppendLine("    $issue")
    }
}
$sw.Stop()
[void]$subTimings.Add(@{ Name = "check_numeric_string_comparison"; DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })

# ============================================================
# Report
# ============================================================
$totalSw.Stop()

if ($anyFailed) {
    Write-Host $failOutput.ToString().TrimEnd()
} else {
    Write-Host "  PASS: All pattern checks passed (code_patterns, logging_hygiene, v1_patterns, send_patterns, display_fields, map_dot_access, dirty_tracking, direct_record_mutation, fr_guard, copydata_contract, scan_pairing, setcallbacks_wiring, cache_path_invariants, numeric_string_comparison)" -ForegroundColor Green
}

Write-Host "  Timing: total=$($totalSw.ElapsedMilliseconds)ms" -ForegroundColor Cyan

# Write sub-timing for nested display (consumed by static_analysis.ps1)
$subTimings | ConvertTo-Json -Compress | Set-Content "$env:TEMP\sa_batch_patterns_timing.json" -Encoding UTF8

if ($anyFailed) { exit 1 }
exit 0
