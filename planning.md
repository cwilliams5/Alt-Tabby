# Planning

Context
- Code lives under `components/` and includes interceptor, logic, GUI, komorebi, winenum, and MRU.
- IPC for Alt-Tab is via RegisterWindowMessage + PostMessage broadcast.
- WindowStore API is referenced by winenum/mru/komorebi_pump but is missing from disk.
- Prior design notes and draft implementations are in `components/Chat GPT Thread.txt`.

Goals (from user)
- Lightning fast Alt-Tab replacement with no perceptible lag.
- Komorebi awareness: workspace scoping, hidden/minimized states, and labeling.
- Clean separation: interceptor, window state, logic, and UI in distinct modules.
- Extendable API for future consumers (e.g., widgets).

Open questions
- Confirm desired GitHub owner and repo name (default: current gh auth user, Alt-Tabby).
- Decide process split: single WindowStore process with producers in-proc vs multi-proc producers.
- Decide store subscription model (full snapshot + deltas, drift strategy, resync policy).
- Define authoritative sources per field (ownership policy) and conflict resolution.
- Decide if GUI stays in-process with logic or is a separate subscriber.

Immediate next steps
- Inventory missing WindowStore implementation and decide rebuild vs import from thread.
- Define minimal IPC contract between WindowStore and AltLogic/GUI.
- Determine startup sequence for winenum, komorebi, and MRU to prime the store.
Project structure
- `legacy/components_legacy/`: historical context only; not used for new implementation.
- `src/store/`: WindowStore + producers + pumps + pipe server.
- `src/interceptor/`: micro interceptor (Alt+Tab hook).
- `src/switcher/`: AltLogic + GUI (consumer).
- `src/viewer/`: debug viewer (consumer).
- `src/shared/`: IPC helpers, config, utilities.
- `tests/`: fixture + live harnesses.
