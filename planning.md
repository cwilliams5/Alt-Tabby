# Alt-Tabby Planning

## Project Goals
- Lightning fast Alt-Tab replacement with no perceptible lag
- Komorebi awareness: workspace scoping, hidden/minimized states, labeling
- Clean separation: interceptor, window state, logic, and UI in distinct processes
- Extendable API for future consumers (widgets, status bars)

## Architecture Decisions (Settled)

### 4-Process Design
1. **Interceptor** (micro): Ultra-fast Alt+Tab hook, isolated for timing
2. **WindowStore + Producers**: Single process with winenum, MRU, komorebi producers
3. **AltLogic + GUI**: Consumer process with overlay and window activation
4. **Debug Viewer**: Diagnostic tool for development

### IPC Model
- Named pipes for multi-subscriber support
- Snapshot + deltas with revision tracking
- Client reconnection with resync on rev mismatch

### Data Flow
```
[WinEnum] ──┐
[MRU]     ──┼──> [WindowStore] ──> Named Pipe ──> [Viewer/GUI/Widgets]
[Komorebi]──┘
```

## Current Status

### Completed
- [x] Commit history cleaned (Codex attribution fixed)
- [x] WindowStore core with projections, upserts, scan APIs
- [x] Named pipe IPC (server + client with adaptive polling)
- [x] Debug viewer (connects and receives data)
- [x] Basic producers (winenum_lite, mru_lite, komorebi_lite)
- [x] Automated testing framework (10 tests passing)
- [x] Bug fix: GetProjection now handles both Map and plain Object opts

### In Progress
- [ ] Documentation updates (CLAUDE.md, planning.md)

### Next Up
- [ ] Port legacy interceptor to `src/interceptor/`
- [ ] Enhance winenum with DWM cloaking detection
- [ ] Replace komorebi polling with subscription-based updates
- [ ] Port legacy GUI as real AltLogic consumer

## Legacy Components to Port

| Component | Source | Target | Priority |
|-----------|--------|--------|----------|
| Interceptor | `legacy/components_legacy/interceptor.ahk` | `src/interceptor/` | HIGH |
| GUI | `legacy/components_legacy/New GUI Working POC.ahk` | `src/switcher/` | HIGH |
| WinEnum features | `legacy/components_legacy/winenum.ahk` | Enhance `winenum_lite.ahk` | MEDIUM |
| Komorebi sub | `legacy/components_legacy/komorebi_sub.ahk` | Replace `komorebi_lite.ahk` | MEDIUM |
| Icon pump | `legacy/components_legacy/icon_pump.ahk` | `src/store/` | LOW |
| Proc pump | `legacy/components_legacy/proc_pump.ahk` | `src/store/` | LOW |

## Testing Strategy
- Unit tests for WindowStore logic (Maps, Objects, sorting)
- Live tests with real window enumeration
- Run before each commit: `.\tests\test.ps1 --live`
- Log output: `%TEMP%\alt_tabby_tests.log`

## Lessons Learned
1. AHK v2 `#Include` is compile-time, not runtime conditional
2. Use `StrCompare()` for string sorting, not `<`/`>` operators
3. `_WS_GetOpt()` pattern handles both Map and Object options
4. Named function refs required for comparators (no inline fat arrows in sort)
5. `/ErrorStdOut` enables headless testing without GUI popups
