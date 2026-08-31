# mcp_apps — read-only MCP Apps for the Terminal-2 lanes

Interactive [MCP Apps](https://apps.extensions.modelcontextprotocol.io) (ext-apps) that render
inside a host like Claude / Claude Desktop. Each tool is bound to a `ui://` HTML app the host shows
in-chat. **Read-only surface** — see the read-only + deferral contract below.

Standalone npm project (like `d4_bridge/`); it is **not** bundled by the root ESLint tooling and its
data all comes from the Python FastAPI app over HTTP — this service holds no DB credentials.

## Tools / apps

| Tool | App | Data source | Notes |
|---|---|---|---|
| `d0-data` | Sales-by-league table | `GET /api/mcp/d0/leagues` | Shared-secret read. |
| `d1-concierge` | Ticket concierge chat | `POST /api/store/retail-chat` | **Reuses the existing retail chat** — one function, no second search path. Gated by `STOREFRONT_CONCIERGE_ENABLED`. |
| `d4-events` | Published events list | `GET /api/mcp/d4/events` | Shared-secret read. Create-event / sell-ticket are **deferred** — buttons render disabled and no write tool exists. |

`routers/mcp.py` (in the main app) serves the `/api/mcp/*` reads, gated by header `X-MCP-Read-Secret`
vs env `MCP_READ_SECRET` (fail-closed 503 when unset).

## Read-only + deferral contract (CLAUDE.md Rule 2)

- Every outbound call is a **GET read** or the existing retail-chat POST to **our own host**.
- **No write path to any listing source** (TEvo / SeatGeek / TickPick / Vivid / SeatData / …) is added
  or reachable from here.
- **D4 create-event / sell-ticket are deferred.** Enforced by the *absence of any write tool*, not just
  disabled UI. They will be wired only when the operator says D4 is ready.

## Environment

| Var | Purpose | Default |
|---|---|---|
| `API_BASE` | Base URL of the FastAPI app | `http://localhost:8000` |
| `MCP_READ_SECRET` | Shared secret sent as `X-MCP-Read-Secret` on `/api/mcp/*` | — |
| `PORT` | Port for the MCP StreamableHTTP endpoint (`/mcp`) | `8787` |

## Build & run (local)

```bash
npm ci
npm run lint      # tsc --noEmit
npm run build     # vite singlefile → dist/<lane>/mcp-app.html (one inlined file per app)
API_BASE=http://localhost:8000 MCP_READ_SECRET=dev-secret PORT=8787 npm start
```

Then point an MCP-Apps host at `http://localhost:8787/mcp` — the ext-apps `basic-host`, the MCP
Inspector, or Claude via a `cloudflared` tunnel as a custom connector. Deploying this as a remote
service (e.g. on Render) is a separate operator-directed step; the repo ships the code only.

## Layout

```
server.ts            McpServer over StreamableHTTP; registers 3 tools + 3 ui:// resources
scripts/build.mjs    builds each apps/<lane> into dist/<lane>/mcp-app.html (singlefile)
apps/<lane>/         mcp-app.html + src/mcp-app.ts (uses the ext-apps App client)
```
