# Terminal-2

Ticket-trading intelligence + primary-market ticketing platform. FastAPI on Render + Supabase Postgres + edge functions + cron-driven ingest from TEvo, SeatGeek, TickPick, Vivid, SeatData, ESPN, NWS. Jointly maintained by a small set of specialized bot lanes coordinating through `public.bot_chat`.

> **Doc version:** v1.2.0 · baseline 2026-05-28 (A1); v1.1.0 2026-06-09 (C1) — *Start here* adds the code knowledge-graph onboarding pointer (→ `PROJECT_BIBLE.md §8`); v1.2.0 2026-06-09 (C1) — pointer now links the committed, viewable chart (`.understand-anything/knowledge-graph-chart.html`). The section-level version + bot-ref convention is defined below under *Doc-writing rules*.

---

## Start here (reading order) *(v1.2 · C1 · 2026-06-09)*

A cold-started bot should read these four, in order. The first is loaded for you automatically every session; the rest you read once at session start.

1. **[`CLAUDE.md`](CLAUDE.md)** — *(auto-loaded every session)* immutable security + operator lockdown rules. The safety baseline; it directs you to read the bible next.
2. **[`PROJECT_BIBLE.md`](PROJECT_BIBLE.md)** — the per-session playbook: hard rules, SQL macros, §3 column-name landmines, workflow recipes, 10-item self-check. **Read this first** of the things you choose to open.
3. **[`BOT_HIERARCHY.md`](BOT_HIERARCHY.md)** — who you are, who can push where, per-lane write scope, Render service ownership.
4. **[`D0_BIBLE.md`](D0_BIBLE.md)** — cross-source ID architecture **+ the full cold-start manual for building the D0 terminal frontend** (PART 1).

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
| [`D0_BIBLE.md`](D0_BIBLE.md) | Cross-source ID architecture (§3) · **full D0 terminal build manual** (PART 1) |
| [`RESOURCES_BIBLE.md`](RESOURCES_BIBLE.md) | Inventory of tables / views / functions / crons / edge functions · **event taxonomy & RULES** |
| [`BOT_HIERARCHY.md`](BOT_HIERARCHY.md) | Bot roster · push authority · Render service scope · per-bot lane scope |
| [`MIGRATION_CONVENTIONS.md`](MIGRATION_CONVENTIONS.md) | Migration filename + header rules · level/lane taxonomy · **landmark-migration log (§14)** |
| [`CRON_HIERARCHY.md`](CRON_HIERARCHY.md) | Cron scheduling policy + job ownership |
| [`SYNC_PROTOCOL.md`](SYNC_PROTOCOL.md) | Repo ↔ deploy ↔ DB sync mechanics |
| [`CHANGELOG.md`](CHANGELOG.md) | Auto-generated release notes (release-please) — **DO NOT hand-edit** |
| [`KANBAN.md`](KANBAN.md) | Open work · drift watchlist · known data-architecture gaps *(append-only)* |

**Historical / non-canonical** (not in the closed set, kept only for the decision trail — do **not** treat as current):
- `docs/archive/` — superseded audits, checkpoints, session logs, handoffs, and the former `LANE_DISCIPLINE.md` / `SCHEMA.md` (folded into BOT_HIERARCHY / RESOURCES_BIBLE respectively).
- `design/` — point-in-time wireframes and design proposals.
- `docs/` (non-archive) — a few active references owned by a canonical doc (e.g. per-bot operating constraints, runbooks the bibles link to). Everything dated/superseded lives under `docs/archive/`.

---

## Doc-writing rules (enforced by CI) *(v1.1 · A1 · 2026-05-28)*

Mirrors `CLAUDE.md §6` (loaded every session) — repeated here because this is where the registry lives.

1. **Do NOT create new root or governance `.md` files.** Add the fact to its owner above. A genuinely new top-level doc is an operator decision — ask first.
2. **One fact, one home — never duplicate; link** (`see <DOC> §<n>`). Duplicated facts are how docs drift out of sync.
3. **Ephemeral work never becomes a new doc.** Audits, checkpoints, session logs, handoffs, status snapshots → `bot_chat` (durable) or `KANBAN.md` (open work). Only if a durable dated artifact is genuinely needed: `docs/archive/YYYY-MM-DD-<topic>.md`.
4. **The gate is real.** `.github/workflows/docs-registry-check.yml` (via `bin/check-docs.sh`) fails any PR that adds a root `*.md` not in this registry, or drops a dated/working-note file into `docs/` outside `docs/archive/`. It runs server-side — `--no-verify` can't skip it.
5. **Version every doc; tag every section change.** Each canonical doc carries a `**Doc version:**` line under its title (semver; the closed set baselines at `v1.0.0` on 2026-05-28). When you add or materially change a section:
   - **Tag the section heading** with `(vX.Y · <BOT> · YYYY-MM-DD)` — a new section starts at `v1.0`; an edit bumps the minor (`v1.1`, `v1.2`, …). Example: `## 4. Canonical SECDEF RPCs *(v1.2 · A1 · 2026-05-28)*`. (Pre-versioning sections carry an implicit `v1.0`; the first edit makes them `v1.1`.)
   - **Bump the doc-version line** — patch for a wording fix, minor for a new/changed section, major for a structural rewrite.
   - This gives a **section-level audit trail** — which bot changed what, when. `CHANGELOG.md` is exempt (release-please-generated). The CI gate fails any registry doc (except `CHANGELOG.md`) missing its `**Doc version:**` line.

---

## Architecture at a glance

```
Browser ─► Render (FastAPI + static) ─► Supabase (Postgres + Auth + Edge Functions)
                 │         │                        ▲
                 │         └─ same-origin session ──┘
                 ├─► TEvo / SG / TickPick / Vivid    (read-only — no writes, CLAUDE.md §2)
                 │
           ┌── pg_cron jobs ─► Edge Functions ─► upstream APIs ─┐
           │                                                    │
           └──────────── cross-bot coordination ── public.bot_chat
```

Full deploy chain (Render services, IDs, testing-unified shell) → `BOT_HIERARCHY.md §7` and `D0_BIBLE.md` (PART 1, deploy chain).

## Repo layout

```
.
├── app.py                  FastAPI shell — all /api/* routes; mounts D2 router
├── *_client.py             TEvo / SeatGeek / TickPick / Vivid / SeatData clients (read-only)
├── d2_dashboard/           D2 orders dashboard + APIRouter (mounted on app.py)
├── d4_bridge/              D4 — Exos/Bridge SPA source (Vite → static/bridge/)
├── static/
│   ├── terminal/           D0 — broker terminal (build manual: D0_BIBLE.md PART 1)
│   ├── store/              D1 — consumer retail storefront
│   ├── home/ undelivered/  D0 hub · D2 undelivered surface
│   ├── bridge/             D4 — Exos Bridge SPA build artifact (committed)
│   └── _shared/            cross-surface utilities
├── supabase/
│   ├── migrations/         YYYYMMDDHHMMSS_descriptive.sql (rules: MIGRATION_CONVENTIONS.md)
│   └── functions/          edge functions
├── bin/                    CI checks (sync-check.sh, check-docs.sh)
├── scripts/ tests/         CI helpers · pytest suite
├── docs/                   active references + docs/archive/ (historical)
├── design/                 historical wireframes / proposals
└── <canonical *.md>        the 11 docs in the registry above
```

## Build / run / deploy the terminal

The complete cold-start manual — frontend file map, the `T.api()` data-fetch architecture, per-page endpoint/RPC contracts, the auth flow, local dev, and the exact Render deploy chain — lives in **[`D0_BIBLE.md`](D0_BIBLE.md) PART 1**. Quick local run:

```powershell
python -m venv .venv; .venv\Scripts\Activate.ps1; pip install -r requirements.txt
cp .env.example .env   # fill SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, etc.
uvicorn app:app --reload --port 8765
```

`http://localhost:8765` → home hub; `/static/terminal/event.html?event=<id>` → D0 broker view.

## Conventions — quick pointers (don't restate; link)

- **Column landmines + TEvo gotchas + SQL macros** → `PROJECT_BIBLE.md §3`
- **Migration filename/header/apply rules** → `MIGRATION_CONVENTIONS.md`
- **Who can push / per-lane scope** → `BOT_HIERARCHY.md` (A1 is sole pusher to `main`)
- **What exists before you build something new** → `RESOURCES_BIBLE.md`
- **Credential rotation** → `MIGRATION_CONVENTIONS.md` vault allowlist + `docs/release-discipline.md §7`
- **Cross-bot coordination** → `public.bot_chat` (durable, append-only) + Slack `#terminal-2-*`

---

**License**: proprietary, internal use. Code authored by Anthropic Claude under operator direction.
