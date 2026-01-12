# Alt-Tabby Assistant Context

## Project Summary
- AHK v2 Alt-Tab replacement focused on responsiveness and low latency.
- Komorebi aware; uses workspace state to filter and label windows.
- Hotkey interception is split into a separate micro process for speed.

## Architecture (4-Process Design)
1. **Interceptor** (micro): Ultra-fast Alt+Tab hook, isolated for timing. Communicates via IPC.
2. **WindowStore + Producers**: Single process hosting store, winenum, MRU, komorebi producers. Named pipe server for multi-subscriber.
3. **AltLogic + GUI**: Consumer process with overlay, MRU selection, window activation.
4. **Debug Viewer**: Diagnostic tool showing Z/MRU-ordered window list from store.

## Current Directory Structure
```
src/
  shared/         - IPC, JSON, config utilities
    config.ahk    - Global settings (pipe names, intervals, feature flags)
    ipc_pipe.ahk  - Named pipe server/client with adaptive polling
    json.ahk      - JSON encoder/decoder (Map and Object aware)
  store/          - WindowStore process
    store_server.ahk    - Main store process with pipe server
    windowstore.ahk     - Core store API (scans, projections, upserts)
    winenum_lite.ahk    - Basic window enumeration producer
    mru_lite.ahk        - Focus tracking producer
    komorebi_lite.ahk   - Komorebi polling producer
  viewer/         - Debug viewer
    viewer.ahk    - GUI with Z/MRU toggle, workspace filter
tests/
  run_tests.ahk   - Automated test suite (unit + live)
  test.ps1        - PowerShell test runner
legacy/
  components_legacy/  - Original ChatGPT work (reference only)
```

## Key Files
- `src/store/store_server.ahk`: WindowStore main entry point
- `src/store/windowstore.ahk`: Core store with GetProjection, UpsertWindow, scan APIs
- `src/shared/ipc_pipe.ahk`: Multi-subscriber named pipe IPC
- `src/viewer/viewer.ahk`: Debug viewer GUI
- `tests/run_tests.ahk`: Automated tests

## Legacy Components (in legacy/components_legacy/)
These are from the original ChatGPT work. Some are battle-tested:
- `interceptor.ahk`: Solid Alt+Tab hook with grace period - **port this**
- `winenum.ahk`: Full-featured enumeration with DWM cloaking - **port features**
- `komorebi_sub.ahk`: Subscription-based updates - **use instead of polling**
- `New GUI Working POC.ahk`: Rich GUI with icons, DWM effects - **port this**
- `mru.ahk`, `icon_pump.ahk`, `proc_pump.ahk`: Mature enrichers

## Guiding Constraints
- **AHK v2 only**: No v1 patterns. Use direct function refs, not `Func("Name")`.
- **Low CPU**: Event-driven, not busy loops. Adaptive polling when needed.
- **Named pipes for IPC**: Multi-subscriber support, no WM_COPYDATA.
- **Testing**: Run `tests/run_tests.ahk --live` to validate changes.

## Recent Lessons Learned
- `_WS_GetOpt()` helper handles both Map and plain Object options
- String sort comparisons must use `StrCompare()` not `<`/`>` operators
- AHK v2 `#Include` is compile-time, cannot be conditional at runtime
- Use `/ErrorStdOut` for silent testing without GUI popups
- Store expects Map records from producers; use `rec["key"]` not `rec.key`

## Testing
Run automated tests before committing:
```powershell
.\tests\test.ps1 --live
```
Or directly:
```
AutoHotkey64.exe /ErrorStdOut tests\run_tests.ahk --live
```
Check `%TEMP%\alt_tabby_tests.log` for results.

## Next Steps (Planned)
1. Port legacy interceptor to `src/interceptor/`
2. Enhance producers with legacy features (DWM cloaking, blacklist)
3. Add komorebi subscription producer (replace polling)
4. Wire legacy GUI as the real AltLogic consumer
