# COWORKER_ONBOARDING.md — Phase 2 (UI handoff)

> **This document was rewritten 2026-05-09 for Phase 2.** Phase 1 (data
> collection) is complete and stable. The prior version of this file
> referenced `static/index.html` and a single-repo design lane that no
> longer exists — that whole UI was deleted in the Phase 1 cleanup.
> Phase 2 starts fresh with a separate UI repo.

---

## TL;DR

You are the UI coworker for Terminal-2. **You don't push to this repo.**
You work in `Terminal-2-ui` (separate repo, link below) and call this
backend's read-only Postgres role + JSON API. The audit lane (me) reviews
and merges your changes.

Three places to look:

| Where | What |
|---|---|
| **Terminal-2-ui** repo | Your codebase. Frontend stack is your choice. |
| **`docs/coworker-handoff/`** in this repo | My notes and instructions for you (the canonical reference) |
| `SCHEMA.md`, `docs/database-map-2026-05-09.md`, `docs/phase2-ui-kanban.md` in this repo | Background reading: schema, data model, kanban backlog |

---

## What Phase 2 is

Phase 1 built the data plane (TEvo + SeatGeek + ESPN + Reddit + Wikipedia +
weather + alerts + odds + AI context bundle). **No UI was built.** Phase 2
is the UI rebuild from scratch.

The first kanban card you'll work on is the **Data Quality Dashboard** —
the dashboard the team uses to know whether the data plane is healthy day
to day. Scope is in `docs/phase2-ui-kanban.md` (sections "Data quality
dashboard" + the priority order at the bottom).

---

## What you have access to

### 1. Read-only Supabase Postgres role: `coworker_readonly`

Connection string + password are delivered out-of-band (see hand-off
package from Julian).

**Can do:**
- `SELECT` on every table and view in `public.*` (~99 tables, ~92 views)
- `EXECUTE` ~23 read-only helper functions including
  `get_event_context(event_id)` — the AI/RAG-style single-call bundle
- Full create/read/update/delete in your own sandbox schema:
  `design_test.*`

**Can NOT do:**
- Insert/update/delete on `public.*` (data plane is owned by audit lane)
- Read `vault.*` or touch `cron.*`
- Execute any function that fires `net.http_*` (data-plane writers, paid pulls)

### 2. JSON API on the FastAPI backend

`https://<railway-deploy>.railway.app/api/*` — 60 read-only routes.
The contract is the route signature; backend semantics are stable.
Bearer-token auth. Token in hand-off package.

Common ones:
- `GET /api/events` — upcoming events list
- `GET /api/events/{event_id}` — single event detail
- `GET /api/broker/event/{event_id}/overview` — full broker bundle
- `GET /api/portfolio` — our orders rollup

You'll see the full list in `app.py` (read-only — link from your repo's
README).

### 3. Supabase MCP (for diagnostic queries during development)

Same `coworker_readonly` role; lets you run ad-hoc SELECTs from your IDE
without writing app code. Useful for designing a query before wiring it up.

---

## What's expected of you

1. **All UI work happens in `Terminal-2-ui`.** Frontend stack is your
   choice (React/Svelte/Vue/Astro/HTMX/vanilla — doesn't matter, pick
   what you'll be productive in).

2. **Open PRs against `main` of `Terminal-2-ui`.** I review and merge.
   Don't merge your own PRs.

3. **You don't push to this repo (`Terminal-2`).** A `CODEOWNERS` file
   + branch-protection rule + CI guard would all reject the PR anyway.
   If you genuinely need a backend change (schema gap, missing API
   route, new function), **open an issue in this repo** describing what
   and why; I'll write + apply it.

4. **Use `design_test.*` for any sandbox tables.** Never `CREATE TABLE
   public.foo` — the role doesn't allow it, but the convention is also
   that `public.*` is owned by the data plane, not UI.

5. **Treat the connection string and Bearer token like any secret.**
   Don't commit them. `.env.local` is your friend; commit `.env.example`
   instead. The hand-off package shows the shape.

---

## What's deprecated from prior onboarding

If you ever see references to:
- `static/index.html`, `templates/`, "design lane editing the broker
  terminal frontend"
- `COWORKER_ONBOARDING.md` mentioning `static/index.html` ownership

Those are pre-Phase-2 and **gone**. The Phase 2 reality is: there is no
frontend code in this repo. The frontend lives in `Terminal-2-ui`.

---

## First-day sequence

1. Accept the GitHub invite to `Terminal-2-ui`.
2. Clone it. Read the README; it points to everything else.
3. Read `docs/phase2-ui-kanban.md` (in `Terminal-2`, linked from your repo's README).
4. Read the Data Quality Dashboard scope in particular.
5. Open an issue in `Terminal-2-ui` describing your design + stack
   choice. Wait for ack before building.
6. Build, PR, review, merge.

---

## Where my notes live

| Document | Purpose |
|---|---|
| `Terminal-2/docs/coworker-handoff/SCOPE.md` | What you can/can't touch, in plain prose |
| `Terminal-2/docs/coworker-handoff/QUERY_COOKBOOK.md` | Ready-to-paste SQL examples for common UI needs |
| `Terminal-2/docs/coworker-handoff/DATA_QUALITY_DASHBOARD.md` | Full scope for your first card |
| `Terminal-2/docs/database-map-2026-05-09.md` | Full schema topology |
| `Terminal-2/docs/phase2-ui-kanban.md` | Backlog (after Data Quality Dashboard) |
| `Terminal-2/SCHEMA.md` | Per-table column reference |
| `Terminal-2-ui/README.md` | Quick start for your repo |

---

## Questions

Open an issue in `Terminal-2-ui` and tag me. Don't DM Slack — issues
keep the discussion attached to the work.
