# Hosting open-notebook on Render

open-notebook ships as Docker images (the single all-in-one image is deprecated in
favor of compose), so Render hosts it cleanly — no local Docker needed.

## Topology (mirrors upstream docker-compose)
| Render service | What | Port | Public? | Disk |
|---|---|---|---|---|
| `open-notebook-db` | SurrealDB `surrealdb/surrealdb:v2` | 8000 | private | `/mydata` 5GB |
| `open-notebook-api` | REST API (FastAPI) | 5055 | **yes** | `/app/data` 5GB |
| `open-notebook-ui` | Web UI (Next.js) | 8502 | **yes** | — |

Two public services because open-notebook's browser frontend calls the API
**directly** (`API_URL`), so the API must be internet-reachable, not just internal.

## Deploy
1. Render Dashboard → **New → Blueprint** → pick this repo, path
   `integrations/open-notebook/render.yaml`.
2. When prompted, set the `sync:false` secrets:
   - `OPEN_NOTEBOOK_PASSWORD` — app login (set the same value on api + ui).
   - `ANTHROPIC_API_KEY` (recommended, for Claude models) and/or `OPENAI_API_KEY`.
   - (`SURREAL_PASSWORD` and `OPEN_NOTEBOOK_ENCRYPTION_KEY` auto-generate and wire
     across services via `fromService`.)
3. Apply. SurrealDB + disks come up first, then api, then ui.

## Cost / guardrails
- Persistent disks require a **paid (Starter+) instance** — SurrealDB and uploaded
  files are stateful and must not run on a free/ephemeral instance.
- This is a **new customer-facing-ish service**. Per BIBLE §2, D0 has Render parity
  with A1 but should post a `bot_chat` `flag` for transparency on provisioning.
- Outbound-data note (CLAUDE.md §2): once live, the publisher sends internal market
  data here, and any model key you set (Anthropic/OpenAI) means briefs leave the
  perimeter at inference time. Self-hosting on our own Render workspace keeps the
  data + DB under our control; the model call is the only egress.

## First-deploy caveats (verify in logs)
- The bundled image runs the API + worker + UI under supervisord on fixed ports.
  We run it twice (api exposes 5055, ui exposes 8502) sharing one SurrealDB. If the
  image ignores `$PORT`, set the Render service's port to 5055 / 8502 explicitly in
  the dashboard, or front it with a small reverse proxy (caddy) — see upstream
  "production" deployment docs.
- `healthCheckPath` is `/health`; if the API has no such route, switch it to `/docs`.

## Wire the publisher
Once `open-notebook-api` is live:
```bash
export OPEN_NOTEBOOK_URL=https://open-notebook-api.onrender.com
export OPEN_NOTEBOOK_NOTEBOOK_ID=<notebook id from the UI>
python publish_event.py 3346012        # publishes the Knicks Finals G4 brief
```
Create a notebook in the UI (e.g. "New York Knicks") first to get its id.
