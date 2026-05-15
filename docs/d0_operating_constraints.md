# D0 Operating Constraints — Consolidated Frontend Lane

D0 = Consolidated Frontend Lane (since 2026-05-15 D-level reorg, `bot_chat` row 157). Was "Terminal FE" pre-reorg.

Companion to [LANE_DISCIPLINE.md §D0](../LANE_DISCIPLINE.md), [BOT_HIERARCHY.md](../BOT_HIERARCHY.md), [CLAUDE.md §4](../CLAUDE.md). Mirrors the pattern of `d1_operating_constraints.md`, `b1_operating_constraints.md`, `c1_operating_constraints.md`.

## Scope

D0 owns all 3 frontend Render services end-to-end (env vars, deploys, configs) plus the terminal code surface directly, plus sign-off authority on D1 and D2 PRs (they author code in their dirs; D0 reviews + signs off before A1 merges).

| Service | Render ID | Code surface | Authored by |
|---|---|---|---|
| `vibepass-terminal-test` | `srv-d839339kh4rs73ac3s20` | `static/terminal/*` | D0 directly |
| `vibepass-storefront-test` | `srv-d8140bnaqgkc73al4asg` | `render.yaml`, `app.py /api/store/*`, `static/store/*` | D1 (D0 signs off) |
| `d2-orders-dashboard` | `srv-d82b4kl7vvec73b4r3r0` | `render-d2-dashboard.yaml`, `d2_dashboard/*` | D2 (D0 signs off) |

## Read surface

- Entire Supabase data plane (RLS-gated reads OK)
- `get_broker_event_page(p_event_id, p_chart_hours)` SECDEF RPC — Path C primary for Event Detail; `@s4kent.com` JWT email gate inside body
- All `/api/broker/*` legacy endpoints in `app.py` (Path A — fallback for localhost dev with `AUTH_DISABLED=true`, and still primary for Home/Movers/Performer pending Phase-2 RPCs)
- All 10 Tier-1 tables granted to authenticated `@s4kent.com` via `d0_s4kent_read` RLS policies (migration 20260515320000): `events`, `event_xref`, `sg_events_canonical`, `aq_event_map`, `aq_venue_map`, `aq_performer_map`, `performer_metadata`, `venue_assets`, `cron_policy`, `cron_gate_decisions`
- D2's dashboard endpoints (`/api/d2/*`) — read-only from terminal's orders doorway via `/healthz` ping; deeper integration requires D2 CORS allowlist
- All `bot_chat` rows (cross-lane coordination history)
- All GitHub PRs / Render service metadata (Render MCP read across all services)

## Write surface

### Local files

- `static/terminal/*` — direct author; all HTML / CSS / JS for the terminal pages, vendored libs (uPlot, supabase-js)
- `docs/event-view-wireframe-*.md`, `docs/performer-view-wireframe-*.md`, `docs/terminal-*.md` — terminal spec docs
- `docs/d0_*.md` — D0 self-contract + planning docs

### Inherited via consolidation (D0 has commit authority; primary author is D1/D2)

- `render.yaml` — storefront IaC blueprint (D1 authors changes; D0 review + sign-off)
- `app.py` `/api/store/*` + `/store/*` routes (D1 lane)
- `static/store/*` (D1 lane)
- `render-d2-dashboard.yaml` (D2 lane)
- `d2_dashboard/*` (D2 lane)

D0 does NOT routinely edit these — D1/D2 stay the primary authors. D0's role is **PR sign-off + Render-side ops** (env vars, redeploy, service config).

### Render workspace (D0 owns 3 services per CLAUDE.md §4 post-reorg)

- Service config: build/start commands, plan, region, branch (per service)
- Env vars: read / set / delete on all 3 services
- Deploys: trigger / restart / monitor
- Runtime logs / metrics

### Supabase tables

D0 does **not** write any Supabase table. Standing exception per [CLAUDE.md](../CLAUDE.md): `bot_chat` writes via `bot_chat_log()` / `bot_chat_resolve()` — append-only multi-writer; D0 uses `bot_lane='Terminal FE'` (legacy label retained; reorg memo'd via row 157), `bot_level='data-collection'`.

## Forbidden actions

- Authoring or applying migrations (A1 lane post-reorg)
- DDL of any kind via MCP (`apply_migration`, `execute_sql` with INSERT/UPDATE/DELETE/DDL)
- Direct writes to D1's `static/store/*` or D2's `d2_dashboard/*` without D1/D2 author awareness (sign-off, not takeover)
- Cron schedule mutations (`cron.schedule`, `cron.unschedule`)
- Edge function deploys that mutate data
- Pushing directly to `main` (A1 sole pusher per [BOT_HIERARCHY §3](../BOT_HIERARCHY.md))
- Bypassing the pytest CI gate (`.github/workflows/tests.yml` since reorg) — green CI is the merge gate
- Touching another lane's Render service: B1/C1 can read all 3; only A1 (workspace-wide) overrides

## Coordination triggers

- **D1/D2 PR opens → D0 review**: leave a sign-off comment on the PR before A1 merges. Block if: lane scope violation, missing tests, breaks an existing terminal page's expectations.
- **Cross-frontend regression** spotted: `bot_chat` `flag` event with both lane refs; D0 coordinates the fix or routes to A1.
- **New backend endpoint** the terminal will consume: D0 → A1 `question` event with the desired RPC signature + JSON shape spec (Path C convention).
- **Render env var change** on any of the 3 services: D0 records via `bot_chat` `change_log` with service ID + var name (never the value).
- **Supabase Auth Redirect URL** changes: operator dashboard action; D0 surfaces the ask via `bot_chat` `question` and confirms post-apply.

## Verification gate

- `node --check` on every JS file edited
- pytest CI (`.github/workflows/tests.yml`) must be green pre-merge
- For terminal UI changes: smoke against the deployed `vibepass-terminal-test` after auto-deploy (localhost dev fallback via `AUTH_DISABLED=true uvicorn app:app --reload --port 8000` when Python env is healthy)
- Path C smoke: hit `supabase.rpc('get_broker_event_page', { p_event_id })` with the Supabase JS client + a signed-in `@s4kent.com` JWT

## Open items / known drift

- [LANE_DISCIPLINE.md line 116](../LANE_DISCIPLINE.md) still reads "D0 has no deploy infra of its own yet" — stale since PR #107 (D0 Render env). Per-service table at line 249 + CLAUDE.md §4 are correct; line 116 paragraph wasn't updated. Flagged for A1 doc-fix.
- LANE_DISCIPLINE.md §D0 was written pre-reorg and does not mention consolidated-frontend scope. A1 owns the §D0 section update per row 157.
- D2's `/api/d2/*` endpoints lack CORS allowlist for `vibepass-terminal-test.onrender.com`. Not blocking — D0 doorway only pings `/healthz` (no auth, no CORS pain). If inline orders summary surfaces later, raise the CORS question to D0-as-coordinator → D2.
- Home/Movers/Performer terminal pages stay on Path A (`/api/broker/*`) until Phase-2 RPCs land. Cross-origin to `vibepass-storefront-test.onrender.com` in prod still needs D1's CORS allowlist OR equivalent RPCs.

## References

- [CLAUDE.md §4](../CLAUDE.md) — Render per-service scoped access
- [LANE_DISCIPLINE.md](../LANE_DISCIPLINE.md) — lane chart + per-service ownership
- [BOT_HIERARCHY.md](../BOT_HIERARCHY.md) — push matrix + table ownership
- [docs/terminal-redesign-2026-05-09.md](terminal-redesign-2026-05-09.md) — 7-page redesign spec
- [docs/event-view-wireframe-v4.md](event-view-wireframe-v4.md) — Event Detail spec
- `bot_chat` row 157 — D-level reorg directive
- `bot_chat` row 145 — Supabase Auth Redirect URL ask (open)
- `bot_chat` row 158 — Path C live for Event Detail
- PR #113 — D0 terminal MVP (current open PR)
- Migration 20260515310000 — `get_broker_event_page` RPC
- Migration 20260515320000 — D0 Tier-1 RLS grants

## Revision history

- 2026-05-15: initial — codifies consolidated frontend scope post-reorg (`bot_chat` row 157)
