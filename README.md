# Terminal-2

Ticket-trading intelligence + primary-market ticketing platform. FastAPI on Render + Supabase Postgres + edge functions + cron-driven ingest from TEvo, SeatGeek, TickPick, Vivid, SeatData, TicketsData, GoTickets, AXS, Eventbrite, Broadway.com, Bandsintown, ESPN, NWS, FRED, X, Wikipedia. Jointly maintained by seven peer bot lanes — a platform substrate (**A1** data plane · **B1** build/guards/docs governance) plus products (**D0** terminal · **D1** store · **D3** broadway · **D4** Exos/Bridge · **D5** fantasy) — coordinating through `public.bot_chat`, with recurring procedures encoded as executable **workflow skills** (`.claude-plugins/`).

> **Doc version:** v2.11.0 (2026-07-08; full drift sweep — intro + reading-order now name **seven** lanes with the new **D5 · Fantasy** product (sports FE `static/fantasy/*` served at `/fantasy/` via the storefront shell); intro + architecture-diagram source lists add Eventbrite / Bandsintown / FRED / X / Wikipedia (and ESPN/NWS in the diagram); repo-layout router list adds `bandsintown`/`eventbrite`/`d0_sales`/`open_notebook` + the `/fantasy` page routes; the `static/` tree gains `fantasy/` and the hub roster is corrected to the live **4-surface** landing (Terminal/Fantasy/Store/Bridge — Undelivered+Orders folded into the Terminal)). · v2.10.0 (2026-07-03; retired the last "prod-DB apply stays A1-centralized" gatekeeper phrase in the reading-order intro — missed in the #785 sweep; now aligns with CLAUDE.md / PROJECT_BIBLE §2.1). · v2.9.0 (2026-07-03; merged #778 drift fixes — intro + reading-order reflect the six-lane model; repo-layout: `server.py` route list corrected, `*_client.py` count 9→10 (+`bandsintown`)) · v2.8.0 (2026-07-03; documented the repo license split — root proprietary `LICENSE` + MIT carve-out for `static/lib/`). · v2.7.0 (2026-07-02; added the `md-table-check` gate to *Doc-writing rules* — `scripts/check_md_tables.py` fails malformed canonical-doc tables). · v2.6.0 (2026-06-28; repo-layout: route decomposition 100%, core/ helper pass, tests/frontend Playwright net, the 5-surface hub as the Render landing). Full prior doc-version history → [`docs/archive/2026-07-02-doc-version-history.md`](docs/archive/2026-07-02-doc-version-history.md).

---

## Start here (reading order)

A cold-started bot reads **two** docs at session start (you don't pre-know your lane, so there are no lane-specific session-start bibles — everything universal is in these two).

1. **[`CLAUDE.md`](CLAUDE.md)** — *(auto-loaded every session)* immutable security + operator lockdown rules. The safety baseline; it directs you to read the bible next.
2. **[`PROJECT_BIBLE.md`](PROJECT_BIBLE.md)** — the per-session playbook: hard rules, **§2 lane assignment / ownership**, SQL macros, §3 column-name landmines, **§5 the full cross-source ID architecture** (absorbed the former D0_BIBLE §3, 2026-06-19), workflow recipes, self-check. **Read its §0 before any cross-source SQL** — source event IDs NEVER line up; everything resolves through the `aq_event_map` hub (the #1 fact cold sessions miss).

On-demand references (read only when relevant, not at session start): **`RESOURCES_BIBLE.md`** (what exists) · **`docs/d0_terminal_build.md`** (build the D0 terminal frontend).

**Seven peer lanes** (D5 fantasy added 2026-07; 2026-07-02 consolidation otherwise): platform substrate **A1** (data plane) · **B1** (build/guards/docs governance); products **D0** (terminal) · **D1** (store) · **D3** (broadway) · **D4** (Exos/Bridge) · **D5** (fantasy). C1 folded into B1, D2 into D0, E1 into A1 — flat lane identifiers, no hierarchy. Push to `main` is **per-task** (no sole-pusher lane; prod-DB apply is per-task by any session under operator direction — no A1 gate). D0 is the priority active lane; D1/D3/D4 paused until D0 ships. Full ownership detail → `PROJECT_BIBLE.md §2`.

Then check **[`KANBAN.md`](KANBAN.md)** for what's actionable right now (don't claim a row marked `[IN PROGRESS by <lane>]`).

**New to the code?** There's an interactive **code knowledge graph** to orient fast (architectural layers, file/function relationships, guided tour). **To view it, open [`.understand-anything/knowledge-graph-chart.html`](.understand-anything/knowledge-graph-chart.html) in a browser** (no toolchain). Regenerate with `/understand` / explore via `/understand-dashboard` — full recipe in **[`PROJECT_BIBLE.md`](PROJECT_BIBLE.md) §8** *("I want to understand the codebase fast")*.

---

## Canonical docs — CLOSED registry

> **This table is the complete, closed set of canonical docs.** To add a fact, edit the doc that **owns** it. **Never create a new root doc.** **Never state a fact in two places — link to its owner instead.** Sprawl regrew once before because nothing gated new-doc creation; now a CI gate enforces this table (see *Doc-writing rules* below).

| Doc | Owns (single source of truth) |
|---|---|
| [`README.md`](README.md) | Entry point · reading order · **this registry** · doc-writing rules |
| [`CLAUDE.md`](CLAUDE.md) | Immutable security + operator lockdown rules · doc-discipline rule *(auto-loaded every session)* |
| [`PROJECT_BIBLE.md`](PROJECT_BIBLE.md) | Per-session playbook: rule summary · SQL macros · **§3 column landmines** · workflow recipes · self-check |
| [`RESOURCES_BIBLE.md`](RESOURCES_BIBLE.md) | Resource catalog: external services · DB inventory (key tables/views/fns/crons/edge fns + live counts) · **cron scheduling policy (§5)** · **event taxonomy & RULES** · data buckets · vault-secret names |
| [`MIGRATION_CONVENTIONS.md`](MIGRATION_CONVENTIONS.md) | Migration filename + header rules · level/lane taxonomy · **landmark-migration log (§14)** |
| [`CHANGELOG.md`](CHANGELOG.md) | Auto-generated release notes (release-please) — **DO NOT hand-edit** |
| [`KANBAN.md`](KANBAN.md) | Open work · drift watchlist · known data-architecture gaps *(open rows deleted on close per its §closure-protocol; the §Archive sections are append-only)* |

**Historical / non-canonical** (not in the closed set, kept only for the decision trail — do **not** treat as current):
- `docs/archive/` — superseded audits, checkpoints, session logs, handoffs, and the former `LANE_DISCIPLINE.md` / `BOT_HIERARCHY.md` / `SCHEMA.md` (lane ownership folded into `PROJECT_BIBLE.md §2`; inventory into `RESOURCES_BIBLE.md`).
- `design/` — point-in-time wireframes and design proposals.
- `docs/` (non-archive) — on-demand references read only when relevant, not session-start bibles: **`docs/d0_terminal_build.md`** (the D0 terminal frontend build manual, ex-`D0_BIBLE.md` PART 1 — its cross-source PART 2 moved to `PROJECT_BIBLE §5`), per-bot operating constraints, runbooks the bibles link to. Everything dated/superseded lives under `docs/archive/`.

---

## Doc-writing rules (enforced by CI)

Mirrors `CLAUDE.md §6` (loaded every session) — repeated here because this is where the registry lives.

1. **Do NOT create new root or governance `.md` files.** Add the fact to its owner above. A genuinely new top-level doc is an operator decision — ask first.
2. **One fact, one home — never duplicate; link** (`see <DOC> §<n>`). Duplicated facts are how docs drift out of sync.
3. **Ephemeral work never becomes a new doc.** Audits, checkpoints, session logs, handoffs, status snapshots → `bot_chat` (durable) or `KANBAN.md` (open work). Only if a durable dated artifact is genuinely needed: `docs/archive/YYYY-MM-DD-<topic>.md`.
4. **The gates are real (server-side; `--no-verify` can't skip).** `docs-registry-check` (`bin/check-docs.sh`) fails any PR adding a root `*.md` not in this registry, or a dated/working-note file in `docs/` outside `docs/archive/`. `md-table-check` (`scripts/check_md_tables.py`) fails any PR whose canonical-doc markdown tables are malformed (a body row whose column count ≠ its header — the mashed-row / stray-`|` failure the registry gate can't see). *(Keeping the bible current when you add a catalogued resource is a judgment prompt — self-check #12 + the PR checklist — not a CI gate; a gate can't tell "needs a doc" from "doesn't.")*
5. **One `**Doc version:**` line per doc; no per-section tags.** Each canonical doc carries a single `**Doc version:**` line under its title (the CI gate fails any registry doc except `CHANGELOG.md` missing it). Bump it on material change. **Do not** add per-heading `(vX · BOT · date)` tags — git blame is the audit trail; inline tags are filler for a bot reader. (Removed 2026-06-19.)

---

## Architecture at a glance

```
Browser ─► Render (FastAPI + static) ─► Supabase (Postgres + Auth + Edge Functions)
                 │         │                        ▲
                 │         └─ same-origin session ──┘
                 ├─► TEvo / SG / TickPick / Vivid / SeatData / TicketsData / GoTickets /
                 │   AXS / Eventbrite / Broadway / Bandsintown / ESPN / NWS / FRED / X /
                 │   Wikipedia                      (read-only — no writes, CLAUDE.md §2)
                 │
           ┌── pg_cron jobs ─► Edge Functions ─► upstream APIs ─┐
           │                                                    │
           └──────────── cross-bot coordination ── public.bot_chat
```

Full deploy chain (Render services, IDs, testing-unified shell) → `PROJECT_BIBLE.md §2.7` and `docs/d0_terminal_build.md` (deploy chain).

## Repo layout

```
.
├── server.py               FastAPI shell — /api/* routes; mounts routers/ + D2
│                           (renamed from app.py 2026-06-26; entrypoint uvicorn server:app)
├── routers/                APIRouter modules include_router'd on server.py
│                           (BR-CODE-1 decomposition — route surface now 100% in
│                           routers/; server.py keeps only /healthz, /webhooks/render,
│                           /api/admin/scheduler-watchdog/status):
│                           site_essentials · catalog · lists · broker · seatdata ·
│                           axs · seatgeek · bandsintown · eventbrite · d0_sales ·
│                           open_notebook · misc (+ /api/public/config) · shares ·
│                           seatmap · retail_chat · store (/api/store/*) · pages
│                           (/, /home, /terminal[/*], /fantasy[/*], /bridge[/*],
│                           /version.json) · store_test (/store/test/*) ·
│                           admin (/api/collect, /api/admin/*) · storefront_pages
│                           (/store, /store/event, /store/{discover,tour}, legal, /s/{id})
├── core/                   shared runtime imported by server.py + routers/ +
│                           *_client.py — one-directional (core never imports
│                           server): config · auth · helpers · broker_helpers ·
│                           movers · search (incl. live/player/cache) · substitutions ·
│                           store_events · observability (logging + opt-in Sentry) ·
│                           db (bounded-timeout Supabase client) · resilience (DB
│                           circuit breaker + retry) · ratelimit (Redis-or-in-proc) ·
│                           readonly_guard · http_retry · vault (shared *_client.py
│                           layer, BR-CODE-2) · discovery · trip_payloads · ingest ·
│                           storefront_html · canonical_refresh (BR-CODE-1 core/
│                           helper pass — bodies injected back via thin server wrappers)
├── *_client.py             10 read-only clients, GET-only by construction (CLAUDE.md
│                           §2): 9 listing-source (evo · seatgeek · tickpick · vivid ·
│                           seatdata · ticketsdata · gotickets · axs · broadway) +
│                           bandsintown (artist tour-dates); share core/readonly_guard ·
│                           http_retry · vault
├── d2_dashboard/           D2 orders dashboard + APIRouter (mounted on server.py)
├── d4_bridge/              D4 — Exos/Bridge SPA source + Express server (Vite → static/bridge/)
├── trip_planner/           shared tour-itinerary optimizer (D0 + D1 trip-plan routes; see its README)
├── broadway_extension/     browser extension — Broadway.com availability capture (see its README)
├── static/
│   ├── terminal/           D0 — broker terminal (build manual: docs/d0_terminal_build.md)
│   ├── store/              D1 — consumer retail storefront (store/test/ = non-prod sandbox)
│   ├── fantasy/            D5 — fantasy (sports) surface, served at /fantasy/ via the
│   │                       storefront shell (spun off from the terminal 2026-07)
│   ├── home/ undelivered/  D0 hub (the 4-surface VibePass landing served at / —
│   │                       Terminal/Fantasy/Store/Bridge; the Render landing when
│   │                       STOREFRONT_AS_LANDING=false. Undelivered+Orders folded
│   │                       into the Terminal) · D2 undelivered
│   ├── bridge/             D4 — Exos Bridge SPA build artifact (committed)
│   └── _shared/            cross-surface utilities
├── supabase/
│   ├── migrations/         YYYYMMDDHHMMSS_descriptive.sql (rules: MIGRATION_CONVENTIONS.md)
│   └── functions/          edge functions
├── bin/                    CI checks (sync-check.sh, check-docs.sh, graph-drift.mjs)
├── scripts/                data/ingest tools + check_readonly.py (RULE 2 static audit, CI gate)
├── tests/                  pytest suite (100% line+branch product-code gate) +
│                           tests/frontend/ = Playwright browser net (smoke +
│                           behavioral; own `frontend-smoke` CI job, isolated via
│                           pytest.importorskip so the main pytest run skips it)
├── .claude-plugins/        governance plugin: skills/ (executable §8 workflows) ·
│   terminal2-governance/   commands/ (/new-migration, /rule2-audit) · hooks/ (Pre+PostToolUse)
├── tests/                  pytest suite (incl. test_readonly_guards.py — RULE 2 runtime guards);
│                           100% product-code line+branch coverage, enforced in CI by
│                           tests.yml --cov-fail-under=100 (.coveragerc scopes the surface)
├── docs/                   active references + docs/archive/ (historical)
├── design/                 historical wireframes / proposals
└── <canonical *.md>        the 7 docs in the registry above
```

## Build / run / deploy the terminal

The complete cold-start manual — frontend file map, the `T.api()` data-fetch architecture, per-page endpoint/RPC contracts, the auth flow, local dev, and the exact Render deploy chain — lives in **[`docs/d0_terminal_build.md`](docs/d0_terminal_build.md)**. Quick local run:

```powershell
python -m venv .venv; .venv\Scripts\Activate.ps1; pip install -r requirements.txt
# Config comes from real environment variables (no .env loader in server.py):
$env:SUPABASE_URL = "https://<project>.supabase.co"
$env:SUPABASE_ANON_KEY = "<anon key>"
$env:SUPABASE_SERVICE_ROLE_KEY = "<service key>"   # + TEVO_API_TOKEN/SECRET etc. as needed
# Observability (all optional): SENTRY_DSN activates error tracking (unset = off),
# LOG_LEVEL tunes stdout logging (default INFO). See core/observability.py.
uvicorn server:app --reload --port 8765
```

`http://localhost:8765` → home hub; `/static/terminal/event.html?event=<id>` → D0 broker view.

Run the test suite + coverage gate locally (mirrors the `tests.yml` CI job). The
dummy creds keep `server.py` from `sys.exit`-ing under coverage's module scan:

```bash
pip install pytest pytest-cov
AUTH_DISABLED=true SUPABASE_URL=https://example.invalid SUPABASE_SERVICE_ROLE_KEY=test-key \
  TEVO_TOKEN=test TEVO_SECRET=test PYTHONPATH=. \
  pytest tests/ --cov --cov-branch --cov-fail-under=100
```

The gate is a **ratchet** — it only moves up. Product code (`server.py`, `core/`,
`routers/`, `d2_dashboard`, the `*_client.py`, `render_webhook.py`) is held at
100% line + branch coverage; genuinely-unreachable lines carry a justified
`# pragma: no cover`. Scope + omits live in `.coveragerc`.

## Conventions — quick pointers (don't restate; link)

- **Cross-source IDs never line up — resolve through the AQ mapper hub** → `PROJECT_BIBLE.md §0` (one-pager) · `PROJECT_BIBLE.md §5` (full architecture)
- **Column landmines + TEvo gotchas + SQL macros** → `PROJECT_BIBLE.md §3` + `§7`
- **Migration filename/header/apply rules** → `MIGRATION_CONVENTIONS.md`
- **Who can push / per-lane scope / who owns each tool** → `PROJECT_BIBLE.md §2` (push to `main` is per-task, no sole-pusher lane; prod-DB apply is per-task by any session under operator direction — no A1 gate)
- **What exists before you build something new** (tables · views · crons · edge fns · vault) → `RESOURCES_BIBLE.md`
- **Where each lane is headed** (north-star + endgame per lane) → `docs/d_tier_goals.md`
- **Edge functions that mutate or burn paid APIs: platform `verify_jwt` is NOT sufficient** → `PROJECT_BIBLE.md §1` rule 7 (`requireCronSecret` pattern)
- **Credential rotation** → `MIGRATION_CONVENTIONS.md` vault allowlist + `docs/release-discipline.md §7`
- **Cross-bot coordination** → `public.bot_chat` (durable, append-only; conventions: `docs/bot_chat_conventions.md`) + Slack `#terminal-2-*`
- **Workflow skills** (executable form of the `PROJECT_BIBLE §8` recipes; auto-surfaced by the PreToolUse router) → `CLAUDE.md §5` · skills live in `.claude-plugins/terminal2-governance/skills/`

---

**License**: proprietary, internal use — All Rights Reserved (see [`LICENSE`](LICENSE)). Code authored by Anthropic Claude under operator direction.

- The repository as a whole is **proprietary / All Rights Reserved** ([`LICENSE`](LICENSE)). Broker clients, ingest pipeline, `server.py`, business logic, and data-source integrations are confidential and may not be used, copied, or redistributed.
- **Carve-out:** [`static/lib/`](static/lib/) (the framework-agnostic **S4K** frontend utilities) is released under the **MIT License** ([`static/lib/LICENSE`](static/lib/LICENSE)). This is the only open-source portion; do not extend MIT coverage to any other path.
