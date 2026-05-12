# LANE_DISCIPLINE.md — bot scope restrictions

Per 2026-05-12 hierarchy restructure. Each bot writes only to its assigned files / tables / crons / edge functions. Out-of-lane writes require PR comment to the lane owner first.

See `docs/bot-hierarchy.mermaid` for the org chart and `MIGRATION_CONVENTIONS.md` for the migration / commit conventions that overlay this scope map.

## Lane assignments

| ID | Lane | Active bot | Status |
|---|---|---|---|
| A1 | Admin / Audit / Push | `mystifying-lederberg-ea407b` | active |
| B1 | Security Manager | `review-supabase-access-v8Dtl` | active |
| C1 | Data + Chat Supervisor | this session | active |
| D0 | Terminal FE (read-only) | `audit-datasets-schemas-auoc3` | reassigned |
| D1 | Consumer Retail + Render workspace owner | `eloquent-chatterjee-aaedf0` | active |
| D2 | Order Clients | `review-unified-order-suite-FA0qA` | active |
| (sub D2) | Undelivered FE | same as D2 (or split when scope activates) | deferred |
| D3 | Broadway (sub of D2) | `broadway-scraper-eChQ6` | active |
| D4 | Our Ticketing Infra | unassigned | future |

## Per-lane restrictions

### A1 — Admin / Audit / Push

**Writes:**
- `app.py` (backend / FastAPI routes shared with D1, coordinate)
- `evo_client.py`, `requirements.txt`, `Procfile`
- `MIGRATION_CONVENTIONS.md`, `SCHEMA.md`, governance docs in `docs/`
- All foundation migrations (ESPN canonical, FRED, listings TTL+dedup+matcher, in-DB matcher)
- `event_xref`, `canonical_external_ids`, `espn_*` ingest tables
- Ledger reconciliation in `supabase_migrations.schema_migrations`
- Cron schedules in `audit-lane` namespace (ESPN, FRED, match_*)

**Reads:** everything.

**Authority:**
- Sole pusher to `main`
- Reviews all PRs against `MIGRATION_CONVENTIONS.md §9` checklist
- Approves merges

### B1 — Security Manager

**Writes (cross-cutting allowed):**
- `KANBAN.md` security backlog
- `docs/security-runbook-*.md`
- `docs/proposed-migrations/*_security_*.sql` (hand-apply gate set)
- `supabase/migrations/*_security_*.sql` (auto-apply set)
- `supabase/functions/_shared/cron-auth.ts`
- Per-lane patches for security CRIT/HIGH (must coordinate via PR comment to lane owner)

**Reads:** everything.

**Authority:**
- Middle-man review between C1 and A1 for security-sensitive PRs
- Resolves `event_type IN ('p0_security', 'flag')` in bot_chat
- Owns hand-apply gate for RLS migrations

### C1 — Data + Chat Supervisor

**Writes:**
- Supervisor-lane migrations (xref governance, queue health views, sweep functions)
- `bot_chat` custodial maintenance (table schema, helper functions)
- Audit docs in `docs/*-audit-*.md`, `docs/*-handoff-*.md`
- Lane discipline + supervisor protocols

**Reads:** everything.

**Authority:**
- Supervises D0-D4 + Undelivered FE
- Routes signals to/from A1, B1
- Logs change_log / sync rows in bot_chat on each PR landing

### D0 — Terminal FE (read-only)

**Writes:**
- Future `static/terminal/*` UI files (when built)
- `docs/event-view-wireframe-*.md`
- `docs/performer-view-wireframe-*.md`
- Other Terminal-FE UI spec docs

**NEVER writes:**
- Any database table
- Any cron schedule
- Any edge function that mutates data
- Any other lane's files
- **Render workspace** (D1 owns; D0 has no deploy infra of its own yet)

**Reads:** entire data plane (charts, predictive models, possibly Grok integration)

### D1 — Consumer Retail

**Writes:**
- `app.py` `/api/store/*` + `/store/*` routes (coordinate with A1)
- `static/store/*.html`, `static/store/*.js`, `static/store/*.css`
- `share_links` table migrations
- `bot_messages` (chat write surface — if D1 owns chat)

**NEVER writes:**
- Broker terminal HTML (`static/index.html`, `static/event.html`, `static/movers.html`)
- Order client `.py` files (D2 territory)
- Broadway scraper (D3)
- Edge functions outside `chat` (if chat moves here)
- Listings / xref infrastructure

**Reads:** events, listings_snapshots, event_metrics, performer / venue context, share_links

**Owns deploy infra:**
- **Render workspace** (sole owner — see Cross-cutting Rule #6). D1 may provision services, modify env vars, configure crons, and manage all Render-side infrastructure for the storefront / `app.py` stack. Other subordinates are explicitly barred from Render writes.

### D2 — Order Clients

**Writes:**
- `seatdata_client.py`, `seatgeek_client.py`, `evo_client.py` (order paths only)
- `tickpick_client.py`, `vivid_client.py`
- `tests/test_readonly_guards.py`, `scripts/check_readonly.py` (RULE 2 enforcement)
- Order tables: `evo_orders`, `evo_order_items`, `evo_orders_pending`, `evo_event_backfill_pending`, `seatgeek_orders`, `seatgeek_order_tickets`, `sg_seller_pending`, `seatdata_sales_snapshots`, `seatdata_pull_budget`, `seatdata_pull_log`
- Order-related crons (evo_orders_*, sg_seller_orders_*, seatdata sales)
- `requirements.txt` (when adding D2-specific deps; pinning shape per A1 convention)

**NEVER writes:**
- Listings infrastructure (`sg_listings_*`, `seatgeek_listings_snapshots`, `seatdata_listings_snapshots`, `seatgeek_seller_listings`) — A1 / canonical
- Storefront files
- Broker terminal files
- Broadway code
- `SCHEMA.md` (propose updates via PR comment to A1)
- **Render workspace** (D1 owns)

**Reads:** events, performer / venue context for join purposes, A1's listings tables for cross-validation

### Undelivered FE (sub of D2)

**Writes:**
- Future `static/undelivered/*` UI when scope activates
- Same scope as D2's order data, **excluding** seatdata

**Reads:** D2's order tables (evo + sg + tickpick + vivid), **NOT** seatdata

### D3 — Broadway (sub of D2)

**Writes:**
- `broadway_client.py`
- `tests/test_broadway_client.py`, `tests/fixtures/checkout_sections_*.html`
- Future `supabase/functions/broadway_collect/index.ts`
- Future `broadway_*` tables (`broadway_shows`, `broadway_performances`, `broadway_sections_snapshots`, `broadway_pull_log`, `broadway_event_xref`)
- `broadway_collect_daily` cron
- Optional vault secret `BROADWAY_USER_AGENT`

**NEVER writes:**
- Order clients
- Storefront
- Other ingest clients
- Edge functions outside `broadway_collect/`
- **Render workspace** (D1 owns)

**Reads:** `canonical_external_ids` for xref propagation (write into own `broadway_event_xref`, propagation handled by drift triggers in A1 / canonical lane)

### D4 — Our Ticketing Infra (future)

**Writes:** TBD when scope activates. AR codes, custom ticketing infrastructure.

**NEVER writes:**
- Anything outside its own future namespace
- **Render workspace** (D1 owns) — D4 gets its own deploy target when scoped, not Render

## Cross-cutting rules

1. **Shared files** — propose changes via PR comment to the owner before editing:
   - `app.py` (A1 owns, D1 has /api/store/*)
   - `requirements.txt` (A1 owns pinning shape; lanes add their own deps)
   - `MIGRATION_CONVENTIONS.md`, `SCHEMA.md`, `AGENTS.md` (A1 / shared)
   - `docs/bot-hierarchy.mermaid` (C1 maintains for restructures)
   - `KANBAN.md` (B1 + A1 share)

2. **Single-writer per table** — see `MIGRATION_CONVENTIONS.md §4`. Each table has one owning lane that writes; others read.

3. **Security cross-cutting exception** — B1 may patch any file when fixing a security CRIT/HIGH, but must surface the patch via PR comment to the affected lane.

4. **Out-of-lane writes** — require PR comment to lane owner before push. If lane owner is offline, surface as `flag` in bot_chat for B1 / A1 resolution.

5. **SECURITY DEFINER convention** — every new SECURITY DEFINER function must ship in one migration with:
   - `REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated`
   - Explicit `GRANT EXECUTE ... TO service_role`
   - `IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN RAISE EXCEPTION` at body start

6. **Deploy infrastructure ownership** — per-lane infra exclusivity:
   - **Render workspace** — owned by **D1 (Consumer Retail)** exclusively. Storefront / app.py / static assets deploy targets. No other subordinate (D0, D2, D3, D4, or future) may provision services, push deploys, or modify environment variables in the Render workspace without explicit operator approval. Render MCP tools (`mcp__render__*`) are gated to D1's lane.
   - **Railway** — current legacy deploy home for the broker terminal + backend. A1 governs migration off Railway → Render as scope warrants. Subordinates do not touch Railway configuration.
   - **Supabase** — shared platform; per-table ownership via `MIGRATION_CONVENTIONS §4`. RLS coverage maintained by B1.
   - **Future D4 infra** — when scope activates, D4 gets its own deploy target. Choice (Render workspace, Cloudflare Workers, custom) deferred until then.

## Enforcement

- A1 catches violations during §9 review
- B1 catches security-class violations
- C1 catches lane-discipline violations in supervised work
- All violations logged as `flag` in `bot_chat`; resolved by B1 (security findings) or A1 (governance)
