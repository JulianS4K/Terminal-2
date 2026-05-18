# Terminal-2

Ticket-trading intelligence + retail platform. FastAPI on Render + Supabase Postgres + 18 edge functions + cron-driven ingest from TEvo, SeatGeek, TickPick, Vivid, SeatData, ESPN, NWS. Multi-bot orchestrated — see [`PROJECT_BIBLE.md`](PROJECT_BIBLE.md).

## Quick links for bots starting a session

| Read first | Why |
|---|---|
| **[`PROJECT_BIBLE.md`](PROJECT_BIBLE.md)** | Operating playbook — hard rules, lane scope, SQL macros, column-name landmines, workflow recipes |
| **[`KANBAN.md §🟢 OPEN WORK`](KANBAN.md)** | Single source of truth for **what's open right now** across all lanes (severity-sorted). Delete your row when you fix it. |
| [`RESOURCES_BIBLE.md`](RESOURCES_BIBLE.md) | Inventory: 132 tables + 152 views + 75+ crons + 40+ edge fns. **Check here before authoring anything new.** |
| [`BOT_HIERARCHY.md`](BOT_HIERARCHY.md) | Who can push to where. A1 is sole pusher to `main`. |
| [`MIGRATION_CONVENTIONS.md`](MIGRATION_CONVENTIONS.md) | Migration filename rules + header + apply protocol |
| [`CLAUDE.md`](CLAUDE.md) | Security rules + 2026-05-13 lockdown invariants |
| [`LANE_DISCIPLINE.md`](LANE_DISCIPLINE.md) | Per-lane write surfaces + cross-lane patch protocol |

## Architecture

```
Browser ─► Render (FastAPI + static)  ─► Supabase (Postgres + Auth + Edge Functions)
                  │                                   ▲
                  ├─► TEvo / SG / TickPick / Vivid    │
                  │   (read-only — no writes per      │
                  │    CLAUDE.md §1 rule 2)           │
                  │                                   │
                  └─► /api/store/* (retail)           │
                                                      │
              ┌── pg_cron (75+ jobs) ─► Edge Function ─┤
              │                              │         │
              └─ upstream APIs ──────────────┘         │
                                                       │
                              cross-bot coordination ──┘
                              via public.bot_chat
```

**Hosted services** (Render):
- `vibepass-storefront-test` — unified shell hosting D0 terminal + D1 storefront + D2 dashboard (testing-unified architecture, PR #168 2026-05-16)
- `vibepass-terminal-test` — static CDN for D0 frontend assets
- `d2-orders-dashboard` — beta-time placeholder, no live traffic

## Repo layout

```
.
├── app.py                            FastAPI shell (all /api/* routes; mounts D2 router)
├── evo_client.py                     TEvo v9 API client
├── *_client.py                       SeatGeek, TickPick, Vivid, SeatData clients (read-only)
├── d2_dashboard/                     D2 orders dashboard + APIRouter (mounted on app.py)
├── static/
│   ├── terminal/                     D0 — broker terminal (event/performer/venue pages)
│   ├── store/                        D1 — consumer retail storefront
│   ├── home/                         D0 home page
│   ├── undelivered/                  D2 undelivered-orders surface
│   └── _shared/                      Cross-surface utilities
├── supabase/
│   ├── migrations/                   318+ migrations (YYYYMMDDHHMMSS_descriptive.sql)
│   └── functions/                    18 edge functions (collect, espn, sg-to-tevo-search-bridge, etc.)
├── docs/                             Bot operating constraints + audits + bibles + war-games
├── design/                           Wireframes + design proposals
├── scripts/                          CI helpers (check_readonly.py, etc.)
├── tests/                            pytest suite
├── KANBAN.md                         Live work board + B1-NEXT security backlog
├── PROJECT_BIBLE.md                  Operating playbook (read first every session)
├── RESOURCES_BIBLE.md                What exists — tables/views/crons/edge fns
├── CLAUDE.md                         Project-wide security rules + lockdown
├── BOT_HIERARCHY.md                  Push restrictions per bot
├── LANE_DISCIPLINE.md                Per-lane write surfaces
├── MIGRATION_CONVENTIONS.md          Migration naming + headers + apply protocol
├── render.yaml                       D1 storefront IaC
├── render-d2-dashboard.yaml          D2 dashboard IaC
└── Procfile                          Web entrypoint: uvicorn app:app
```

## Local dev

```powershell
# Install deps (pinned in requirements.txt)
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt

# Env from .env.example
cp .env.example .env  # then fill SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, etc.

# Run
uvicorn app:app --reload --port 8765
```

Browser at `http://localhost:8765` lands on the home page. `/static/terminal/event.html?event=<id>` for the D0 broker view.

## Production deploys

Auto-deploys on `main` push via Render. See `render.yaml` + `render-d2-dashboard.yaml` for IaC. A1 is sole pusher to `main`; subordinate bots open PRs against `main`.

## Bot orchestration (the short version)

This repo is jointly maintained by ~10 specialized bot lanes (A1 admin, B1 security, C1 canonical drift, D0 terminal FE, D1 storefront, D2 orders, D3 scrapers, D4 ticketing infra, E1 external markets). Coordination happens via the `public.bot_chat` table (durable, append-only) + scheduled-task heartbeats + Slack channels (`#terminal-2-alerts`, `#terminal-2-admin`, `#terminal-2-d0`).

If you're a bot starting a session: **read `PROJECT_BIBLE.md` first, then check `KANBAN.md §🟢 OPEN WORK`** for what's currently actionable. Don't claim work that's already in flight (the row is annotated `[IN PROGRESS by <lane>, PR #<n>]`).

If you're a human reading this: most operational decisions are recorded in the docs/audits/checkpoints under `docs/`. The 2026-05-13 SQL-data lockdown means prod DB mutations require explicit operator approval per call.

## TEvo gotchas (still relevant)

- `event.available_count` is deprecated. Use `get_event_stats()`.
- `event.occurs_at` has a `Z` suffix but is **LOCAL time**. Use `occurs_at_local`.
- Canonical signing string always includes `?`, even with empty query.
- Rate limit ~5 req/sec sustained. Collectors pace at 3 concurrent × 200ms + retry-on-429.
- `/v9/events` date filter uses **dotted notation**: `"occurs_at.gte"` (underscore form `occurs_at_gte` returns 422). See `PROJECT_BIBLE.md §3` column landmines for the full set.

## Credential rotation

**TEvo creds** (no redeploy — stored in `settings` table):
```sql
update settings set value = 'new_token',  updated_at = now() where key = 'tevo_token';
update settings set value = 'new_secret', updated_at = now() where key = 'tevo_secret';
```

**Allowed domain** (Render env):
```powershell
# Render dashboard → vibepass-storefront-test → Environment → ALLOWED_EMAIL_DOMAIN
```

**Vault secrets** (per `MIGRATION_CONVENTIONS.md` allowlist): use `get_app_secret()` from Postgres. See `docs/release-discipline.md §7` for rotation runbook.

## Useful queries

```sql
-- Current state of every tracked event
SELECT e.name, e.occurs_at_local, em.listings_all_min, em.listings_owned_min
FROM events e
LEFT JOIN seatgeek_event_metrics em ON em.tevo_event_id = e.id
WHERE e.occurs_at_local > now()
ORDER BY e.occurs_at_local
LIMIT 20;

-- Release health (one-shot smoke harness, B1-owned)
SELECT * FROM public.release_health_check() WHERE status <> 'ok';

-- What's unresolved across bots
SELECT id, event_type, bot_lane, created_at, substring(message, 1, 100)
FROM public.bot_chat
WHERE resolved_at IS NULL
  AND event_type IN ('p0_security','flag','question')
ORDER BY created_at DESC
LIMIT 20;
```

---

**License**: proprietary, internal use. Code authored by Anthropic Claude under operator direction.
