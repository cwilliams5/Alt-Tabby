# Alt-Tabby Architecture

## Multi-Process Model

Single `AltTabby.exe` serves as launcher and all process modes:

**User-facing modes:**
- `AltTabby.exe` - Launcher (spawns store + gui, manages tray)
- `--store` - WindowStore server only
- `--gui-only` - GUI only (requires store)
- `--viewer` - Debug viewer
- `--config` / `--blacklist` - Editor GUIs

**Internal modes:** `--wizard-continue`, `--enable-admin-task`, `--repair-admin-task`, `--apply-update`, `--update-installed`, `--skip-mismatch`

## Process Roles

1. **Launcher**: Tray icon, subprocess PIDs, on-demand menu updates
2. **WindowStore + Producers**: Named pipe server, window data
3. **AltLogic + GUI**: Overlay, MRU selection, window activation
4. **Debug Viewer**: Z/MRU-ordered window list display

## Key Files

- `VERSION` - Single source for version (e.g., `0.6.0`)
- `src/alt_tabby.ahk` - Unified entry point
- `src/store/windowstore.ahk` - Core store API
- `src/shared/ipc_pipe.ahk` - Multi-subscriber named pipe IPC
- `src/shared/config_registry.ahk` - All config definitions
- `src/shared/blacklist.ahk` - Window eligibility logic
- `src/gui/gui_main.ahk` - Alt-Tab GUI overlay

## Producer Architecture

- **WinEventHook** (always enabled) - Primary for window changes AND MRU
- **MRU_Lite** - Fallback only if WinEventHook fails
- **Komorebi** - Optional, graceful handling if not running
- **WinEnum** - On-demand (startup, snapshot, Z-pump), not polling
- **Only winenum calls BeginScan/EndScan** - others use UpsertWindow/UpdateFields

## Producer Observability

States in projection meta: `"running"`, `"failed"`, `"disabled"`
- `meta.producers`: `{ wineventHook, mruLite, komorebiSub, komorebiLite, iconPump, procPump }`
- No automatic retry - if producer fails at startup, it stays failed

## Centralized Window Eligibility

**All eligibility logic in `Blacklist_IsWindowEligible()`** - combines Alt-Tab rules AND blacklist filtering. All producers MUST use this single function.

## State Machine

```
IDLE ──Alt down──> ALT_PENDING ──Tab──> ACTIVE ──Alt up──> IDLE
                        │                  │
                        │ Alt up (quick)   │ Escape
                        v                  v
                   (quick switch)       (cancel)
```

States: `IDLE`, `ALT_PENDING`, `ACTIVE`

## Critical Design Decisions

1. **Lock-in on first Tab** - Projection frozen when Tab pressed (not Alt)
2. **Pre-warm on Alt** - Request snapshot early for fresh data
3. **GUI always running** - Show/hide, don't create/destroy
4. **Keyboard hooks in GUI process** - Zero IPC latency
5. **Grace period ~150ms** - Quick Alt+Tab = instant switch

## Config System

- All values in `global cfg := {}` object
- Single source: `gConfigRegistry` in `config_registry.ahk`
- Access via `cfg.PropertyName`
- **ConfigLoader_Init() must be called before using cfg**

## Key Metrics

- Alt+Tab detection: <5ms
- GUI show after Tab: <50ms
- Quick switch: <25ms total
