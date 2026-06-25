# Terminal-2

Ticket-trading intelligence + primary-market ticketing platform. FastAPI on Render + Supabase Postgres + edge functions + cron-driven ingest from TEvo, SeatGeek, TickPick, Vivid, SeatData, TicketsData, GoTickets, AXS, Broadway.com, ESPN, NWS. Jointly maintained by four peer bot domains — **A1** (data plane), **B1** (git/code), **C1** (docs/coordination), **D0–D4** (frontend surfaces) — coordinating through `public.bot_chat`, with recurring procedures encoded as executable **workflow skills** (`.claude-plugins/`).

> **Doc version:** v2.1.0 (2026-06-25; added the product-code coverage gate to repo-layout + local-run; history in git/CHANGELOG)

---

## Start here (reading order)

A cold-started bot reads **two** docs at session start (you don't pre-know your lane, so there are no lane-specific session-start bibles — everything universal is in these two).

1. **[`CLAUDE.md`](CLAUDE.md)** — *(auto-loaded every session)* immutable security + operator lockdown rules. The safety baseline; it directs you to read the bible next.
2. **[`PROJECT_BIBLE.md`](PROJECT_BIBLE.md)** — the per-session playbook: hard rules, **§2 lane assignment / ownership**, SQL macros, §3 column-name landmines, **§5 the full cross-source ID architecture** (absorbed the former D0_BIBLE §3, 2026-06-19), workflow recipes, self-check. **Read its §0 before any cross-source SQL** — source event IDs NEVER line up; everything resolves through the `aq_event_map` hub (the #1 fact cold sessions miss).

On-demand references (read only when relevant, not at session start): **`RESOURCES_BIBLE.md`** (what exists) · **`docs/d0_terminal_build.md`** (build the D0 terminal frontend).

**Four peer domains** (2026-06-17 reorg): **A1** data plane · **B1** git/code · **C1** docs/coordination · **D0–D4** distinct FE surfaces. Push to `main` is **per-task** (A1 + B1 maintain; prod-DB apply stays A1-centralized). D0 is the priority active lane; D1–D4 paused until D0 ships; E1 folded into A1. Full ownership detail → `PROJECT_BIBLE.md §2`.

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
4. **The gate is real (server-side; `--no-verify` can't skip).** `docs-registry-check` (`bin/check-docs.sh`) fails any PR adding a root `*.md` not in this registry, or a dated/working-note file in `docs/` outside `docs/archive/`. *(Keeping the bible current when you add a catalogued resource is a judgment prompt — self-check #12 + the PR checklist — not a CI gate; a gate can't tell "needs a doc" from "doesn't.")*
5. **One `**Doc version:**` line per doc; no per-section tags.** Each canonical doc carries a single `**Doc version:**` line under its title (the CI gate fails any registry doc except `CHANGELOG.md` missing it). Bump it on material change. **Do not** add per-heading `(vX · BOT · date)` tags — git blame is the audit trail; inline tags are filler for a bot reader. (Removed 2026-06-19.)

---

## Architecture at a glance

```
Browser ─► Render (FastAPI + static) ─► Supabase (Postgres + Auth + Edge Functions)
                 │         │                        ▲
                 │         └─ same-origin session ──┘
                 ├─► TEvo / SG / TickPick / Vivid / SeatData / TicketsData /
                 │   GoTickets / AXS / Broadway     (read-only — no writes, CLAUDE.md §2)
                 │
           ┌── pg_cron jobs ─► Edge Functions ─► upstream APIs ─┐
           │                                                    │
           └──────────── cross-bot coordination ── public.bot_chat
```

Full deploy chain (Render services, IDs, testing-unified shell) → `PROJECT_BIBLE.md §2.7` and `docs/d0_terminal_build.md` (deploy chain).

## Repo layout

```
.
├── app.py                  FastAPI shell — all /api/* routes; mounts D2 router
├── *_client.py             9 read-only listing-source clients: evo · seatgeek ·
│                           tickpick · vivid · seatdata · ticketsdata · gotickets ·
│                           axs · broadway (GET-only by construction, CLAUDE.md §2)
├── d2_dashboard/           D2 orders dashboard + APIRouter (mounted on app.py)
├── d4_bridge/              D4 — Exos/Bridge SPA source + Express server (Vite → static/bridge/)
├── trip_planner/           shared tour-itinerary optimizer (D0 + D1 trip-plan routes; see its README)
├── broadway_extension/     browser extension — Broadway.com availability capture (see its README)
├── static/
│   ├── terminal/           D0 — broker terminal (build manual: docs/d0_terminal_build.md)
│   ├── store/              D1 — consumer retail storefront (store/test/ = non-prod sandbox)
│   ├── home/ undelivered/  D0 hub · D2 undelivered surface
│   ├── bridge/             D4 — Exos Bridge SPA build artifact (committed)
│   └── _shared/            cross-surface utilities
├── supabase/
│   ├── migrations/         YYYYMMDDHHMMSS_descriptive.sql (rules: MIGRATION_CONVENTIONS.md)
│   └── functions/          edge functions
├── bin/                    CI checks (sync-check.sh, check-docs.sh, graph-drift.mjs)
├── scripts/                data/ingest tools + check_readonly.py (RULE 2 static audit, CI gate)
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
# Config comes from real environment variables (no .env loader in app.py):
$env:SUPABASE_URL = "https://<project>.supabase.co"
$env:SUPABASE_ANON_KEY = "<anon key>"
$env:SUPABASE_SERVICE_ROLE_KEY = "<service key>"   # + TEVO_API_TOKEN/SECRET etc. as needed
uvicorn app:app --reload --port 8765
```

`http://localhost:8765` → home hub; `/static/terminal/event.html?event=<id>` → D0 broker view.

Run the test suite + coverage gate locally (mirrors the `tests.yml` CI job). The
dummy creds keep `app.py` from `sys.exit`-ing under coverage's module scan:

```bash
pip install pytest pytest-cov
AUTH_DISABLED=true SUPABASE_URL=https://example.invalid SUPABASE_SERVICE_ROLE_KEY=test-key \
  TEVO_TOKEN=test TEVO_SECRET=test PYTHONPATH=. \
  pytest tests/ --cov --cov-branch --cov-fail-under=100
```

The gate is a **ratchet** — it only moves up. Product code (`app.py`, `core/`,
`routers/`, `d2_dashboard`, the `*_client.py`, `render_webhook.py`) is held at
100% line + branch coverage; genuinely-unreachable lines carry a justified
`# pragma: no cover`. Scope + omits live in `.coveragerc`.

## Conventions — quick pointers (don't restate; link)

- **Cross-source IDs never line up — resolve through the AQ mapper hub** → `PROJECT_BIBLE.md §0` (one-pager) · `PROJECT_BIBLE.md §5` (full architecture)
- **Column landmines + TEvo gotchas + SQL macros** → `PROJECT_BIBLE.md §3` + `§7`
- **Migration filename/header/apply rules** → `MIGRATION_CONVENTIONS.md`
- **Who can push / per-lane scope / who owns each tool** → `PROJECT_BIBLE.md §2` (push to `main` is per-task; A1 + B1 maintain it; prod-DB apply centralized on A1)
- **What exists before you build something new** (tables · views · crons · edge fns · vault) → `RESOURCES_BIBLE.md`
- **Where each lane is headed** (north-star + endgame per lane) → `docs/d_tier_goals.md`
- **Edge functions that mutate or burn paid APIs: platform `verify_jwt` is NOT sufficient** → `PROJECT_BIBLE.md §1` rule 7 (`requireCronSecret` pattern)
- **Credential rotation** → `MIGRATION_CONVENTIONS.md` vault allowlist + `docs/release-discipline.md §7`
- **Cross-bot coordination** → `public.bot_chat` (durable, append-only; conventions: `docs/bot_chat_conventions.md`) + Slack `#terminal-2-*`
- **Workflow skills** (executable form of the `PROJECT_BIBLE §8` recipes; auto-surfaced by the PreToolUse router) → `CLAUDE.md §5` · skills live in `.claude-plugins/terminal2-governance/skills/`

---

**License**: proprietary, internal use. Code authored by Anthropic Claude under operator direction.
