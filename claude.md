# Alt-Tabby assistant context

Project summary
- AHK v2 Alt-Tab replacement focused on responsiveness and low latency.
- Komorebi aware; uses workspace state to filter and label windows.
- Hotkey interception is split into a separate micro process for speed.

Current entrypoints
- `components/switcher.ahk`: main logic + GUI (legacy wiring).
- `components/interceptor.ahk`: ultra light Alt-Tab interceptor using PostMessage IPC.

Key modules
- `components/altlogic.ahk`: session logic, list building, activation.
- `components/komorebi_sub.ahk`: komorebi subscription via named pipe.
- `components/winenum.ahk`: fast Z-order enumeration, optional store hooks.
- `components/mru.ahk`: MRU tracking updates.
- `components/icon_pump.ahk` / `components/proc_pump.ahk`: background enrichers.
- `components/gui.ahk` and `components/New GUI Working POC.ahk`: UI layers.

Architecture direction
- Planned WindowStore API as single source of truth for window state.
- Producers push into WindowStore; consumers subscribe or request projections.
- Minimize blocking in hot paths; use batching and async pumps.

Notes
- The WindowStore implementation is not currently present in this repo; see
  `components/Chat GPT Thread.txt` for prior draft API and refactors.