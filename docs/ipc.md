# IPC Schema (v1)

Transport
- Named pipe server hosted by WindowStore: `\\.\pipe\tabby_store_v1`
- Messages are newline-delimited JSON (one message per line).
- Multi-subscriber: store broadcasts to all connected clients.

Common fields
- `type`: string message type.
- `rev`: store revision at time of message.
- `baseRev`: client rev that the delta is based on (delta messages only).
- `payload`: message data.

Client -> Store
- `hello`: `{ projectionOpts? }` - Register client and receive initial snapshot
- `snapshot_request`: `{ projectionOpts? }` - Request fresh snapshot (triggers full window scan)
- `projection_request`: `{ projectionOpts? }` - Request projection without triggering scan
- `set_projection_opts`: `{ projectionOpts }` - Update client's projection options
- `reload_blacklist`: `{}` - Triggers blacklist file reload and purges matching windows
- `producer_status_request`: `{}` - Request current producer states
- `ping`: `{}`

Store -> Client
- `hello_ack`: `{ payload: { meta, capabilities } }`
- `snapshot`: `{ rev, payload: { meta, items } }`
- `delta`: `{ rev, baseRev, payload: { upserts, patches, removes, meta } }`
- `projection`: `{ rev, payload: { meta, items | hwnds } }`
- `heartbeat`: `{ rev }` - Sent periodically (default 5s) for connection health
- `producer_status`: `{ producers }` - Response to producer_status_request
- `error`: `{ code, message }`

Projection options
- `currentWorkspaceOnly`: bool - Filter to current komorebi workspace
- `includeMinimized`: bool - Include minimized windows (default true)
- `includeCloaked`: bool - Include cloaked/hidden windows (default false)
- `sort`: "MRU" | "Z" | "Title" | "Pid" | "ProcessName" - Sort order
- `columns`: "items" | "hwndsOnly" - Full items or just hwnd list

Note: Blacklist filtering happens at producer level. Blacklisted windows never enter the store.

Meta object
- `currentWSId`: current workspace ID (string)
- `currentWSName`: current workspace name (string)

Note: Producer status is NOT included in meta (reduces delta/snapshot bloat).
Use `producer_status_request` to get producer states on demand.

Producer status object
- `wineventHook`: "running" | "failed" | "disabled"
- `mruLite`: "running" | "failed" | "disabled"
- `komorebiSub`: "running" | "failed" | "disabled"
- `komorebiLite`: "running" | "failed" | "disabled"
- `iconPump`: "running" | "failed" | "disabled"
- `procPump`: "running" | "failed" | "disabled"

Resync behavior
- If client receives `delta.baseRev` that does not match its last known `rev`, it should request a full `snapshot`.
- Heartbeat includes `rev` for drift detection - if store rev > local rev, client missed updates.
- Optional periodic snapshot (e.g. every 60s) is acceptable for drift protection.
