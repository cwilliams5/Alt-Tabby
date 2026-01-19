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
- `hello`: `{ clientId, wants: { deltas: true }, projectionOpts }`
- `snapshot_request`: `{ includeItems: true, projectionOpts }`
- `projection_request`: `{ projectionOpts }`
- `set_projection_opts`: `{ projectionOpts }`
- `reload_blacklist`: `{}` - triggers blacklist file reload and purges matching windows
- `producer_status_request`: `{}` - request current producer states
- `ping`: `{}`

Store -> Client
- `hello_ack`: `{ rev, meta, capabilities }`
- `snapshot`: `{ rev, meta, items }`
- `delta`: `{ rev, baseRev, upserts, patches, removes, meta }`
- `projection`: `{ rev, meta, items }`
- `heartbeat`: `{ rev }` - sent periodically (default 5s) for connection health
- `producer_status`: `{ producers }` - response to producer_status_request
- `error`: `{ code, message }`

Projection options
- `currentWorkspaceOnly`: bool
- `includeMinimized`: bool
- `includeCloaked`: bool
- `blacklistMode`: "exclude" | "include" | "only"
- `sort`: "MRU" | "Z" | "Title" | "Pid" | "ProcessName"
- `columns`: "items" | "hwndsOnly"

Meta object
- `currentWSId`: current workspace ID (string)
- `currentWSName`: current workspace name (string)
- Note: Producer status is NOT included in meta (reduces delta/snapshot bloat)
- Use `producer_status_request` to get producer states on demand

Producer status object
- `wineventHook`: "running" | "failed" | "disabled"
- `mruLite`: "running" | "failed" | "disabled"
- `komorebiSub`: "running" | "failed" | "disabled"
- `komorebiLite`: "running" | "failed" | "disabled"
- `iconPump`: "running" | "failed" | "disabled"
- `procPump`: "running" | "failed" | "disabled"

Resync behavior
- If client receives `delta.baseRev` that does not match its last known `rev`, it should request a full `snapshot`.
- Optional periodic snapshot (e.g. every 60s) is acceptable for drift protection.