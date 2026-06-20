# D4 Operating Constraints — The Bridge (Ticketing Infra)

D4 = **The Bridge** lane: primary-market ticketing intake + distribution to S4K's retail channels. Activating 2026-05-20 (was "UNASSIGNED / future"). Reports to C1 (hierarchy); subordinate-coding posture under D0 for any shared frontend surface.

This doc codifies the boundaries D4 operates within. **Read first:** [`docs/d4_bridge_charter.md`](d4_bridge_charter.md) (scope + architecture), `CLAUDE.md §4` (Render scope), `PROJECT_BIBLE.md §2` (deploy ownership · push matrix · per-lane scope — absorbed the former `PROJECT_BIBLE.md §2` on 2026-05-28). This file fills in D4-specific operational detail.

## Posture (activation, pre-implementation)

D4 is **chartered but pre-build**. Until the §6 governance items in the charter are signed off, D4's effective surface is **read + author-docs/migrations-as-files only** — same standing as any D-tier bot. Specifically:
- **No upstream WRITE** until the per-platform listing carve-out is chartered + **operator-authorized** (charter §6.1). This is the gating blocker for the whole product.
- **No own Render service yet** — A1 provisions `vibepass-bridge-*` when the integration layer needs a deploy target.
- **Render MCP READ-ONLY** across all services (CLAUDE.md §4 — D4 is in the read-only tier with B1/C1/D3/E1).

## Scope

D4 owns the **Bridge integration layer**: inventory ingest from the venue-intake platform, floor-price control (venue/operator-set in P1; D0 feed later), multi-platform distribution push, oversell/sync guard, and buyer-data capture. D4 does **not** rebuild ticketing primitives (checkout/QR/Stripe) — those come from the Hi.Events/pretix fork. Single-writer to the `bridge_*` table namespace.

## Read surface (allowed sources)

| Object / source | Owner lane | What D4 uses it for |
|---|---|---|
| `get_broker_event_page_v2`, `get_event_chart_extended` (SECDEF RPCs) | D0/A1 | pricing intelligence for floor calibration — **deferred (D4 independent from D0 for now; P1 floors venue/operator-set)** |
| `seatgeek_event_metrics`, `seatgeek_sales_snapshots`, `seatgeek_listings_snapshots`, `listings_snapshots` | A1 | secondary-market price/velocity signals (mind the dedupe + column landmines, `PROJECT_BIBLE.md §3`) |
| `events`, `aq_event_map`, `event_xref`, `seatgeek_event_xref` | A1/C1 | cross-source event identity; xref Bridge events into the canonical key |
| `performer_metadata`, `venue_assets` | A1 | event/venue context |
| D2 order clients (`evo_client.py`, `seatgeek_client.py`, `tickpick_client.py`, `vivid_client.py`, `gotickets_client.py`) | D2 | **read methods only** today; import + call (do not edit) |
| `bot_chat` | shared | cross-lane coordination |

If D4 needs a new read against a table it doesn't already use, ack the owner lane in `bot_chat` first.

## Write surface (D4 is the writer)

### Local files
- `d4_bridge/*` (or `bridge/*`) — integration-layer service code (proposed; confirm dir name with A1).
- `*_listing_client.py` — sibling write modules to D2's read clients (**only after §6.1 carve-out**; D2 co-owns).
- `supabase/functions/bridge-*` — inventory-ingest / push / reconcile edge fns (must carry proper auth per lockdown rule #7).
- `supabase/migrations/*_bridge_*.sql` — authored as files by D4; **applied to prod by A1 only**.
- `docs/d4_*.md` — D4 self-contract + planning/charter docs.
- `KANBAN.md` — append-only, D4 rows in `(D4 → A1)` style.

### Supabase tables (D4 single-writer — proposed namespace)
`bridge_clients`, `bridge_events`, `bridge_inventory`, `bridge_distributions`, `bridge_buyers`, `bridge_event_xref`, `bridge_pull_log`. All single-writer; created via A1-applied migrations. `bridge_buyers` (PII) requires B1 RLS review before ship (charter §6.5).
`bot_chat` — append-only multi-writer; D4 posts with `bot_lane='D4'`, `bot_level='data-collection'`.

### Render workspace — READ-ONLY (until D4's own service exists)
D4 reads via Render MCP (`get_service`, `list_deploys`, `list_logs`). No writes on any service. When A1 provisions `vibepass-bridge-*`, D4 gets write scope on **that service only**; cross-service writes stay forbidden.

## Forbidden actions

D4 **must not**:
1. **Write to any upstream API** (order/listing/hold/inventory POST/PUT/DELETE on SG/TEvo/TickPick/Vivid/GoTickets/etc.) until the §6.1 carve-out is chartered **and** the operator authorizes that platform. This is the hard gate.
2. **Edit D2's order clients** directly (`evo_client.py`, `seatgeek_client.py`, `tickpick_client.py`, `vivid_client.py`, `gotickets_client.py`, `seatdata_client.py`) — propose via PR comment / `bot_chat`; build sibling modules instead.
3. **Run `apply_migration` against the prod project.** Migrations land via PR → A1. Preview branches (`create_branch`) OK for validation.
4. **Push to `main`.** A1 is sole pusher (B1 for CRIT security). D4 ships via PR.
5. **Write Render env vars / config on any service** (read-only tier until D4's own service is provisioned).
6. **Edit other lanes' files** — storefront (`static/store/*`, D1), terminal (`static/terminal/*`, D0), dashboard (`d2_dashboard/*`, D2), broadway (`broadway_client.py`, D3), canonical migrations / `SCHEMA.md` outside D4's sections, governance docs (`PROJECT_BIBLE.md §2`, `PROJECT_BIBLE.md §2`, `PROJECT_BIBLE.md` — A1-owned).
7. **Capture buyer PII** before B1 reviews RLS / retention / export posture.
8. **Echo secrets** (Stripe keys, platform API tokens, Supabase service-role key) in chat or commits — env-var indirection only.

## Coordination triggers

File a `bot_chat` flag/question **before**:
- Beginning any upstream-write work → operator authorization + B1 sign-off (§6.1).
- Adding a write path to a D2 client surface → D2 + B1.
- New `bridge_*` table / column / index → A1 review.
- Any buyer-PII surface change → B1.
- New edge function or cron → A1 (+ lockdown rule #7 auth check).
- Provisioning a Render service → A1 (D4 cannot self-provision until scoped).
- New outbound service call (Stripe, the intake platform's API) → CSP / secret-handling review with B1.

## Onboarding requirement (CLAUDE.md §5)

On activation D4 must create a lane-scoped **aging-sweep scheduled task** (hourly, unique minute offset from the registry; HEARTBEAT pattern; posts to `#terminal-2-d0`). **Pending** — claim a slot in the `CLAUDE.md §5` registry (open: `:05 :10 :20 :25 :30 :35 :40 :50 :55`) when A1 confirms activation.

## Verification gate

- `node --check` on JS edited; pytest CI green pre-merge (`.github/workflows/tests.yml`).
- New listing-write modules: read-only guard tests for the **original** D2 clients stay green (`tests/test_readonly_guards.py`).
- Inventory/oversell logic: unit tests asserting Σ(live secondary listings) ≤ remaining primary inventory across concurrent-sale scenarios.

## Open items / known drift

- Governance docs still list D4 "UNASSIGNED / future" — A1 owns the status flip (charter §8.6).
- `hi-events` Render service (`srv-d7g0cev7f7vs73blkc70`) role unconfirmed (fork vs. eval) — charter §8.2.
- Hi.Events vs pretix not yet selected — charter §8.1.
- Upstream-write carve-out unwritten — charter §6.1 (the build blocker).

## References

- [`docs/d4_bridge_charter.md`](d4_bridge_charter.md) — scope + architecture + governance reconciliation.
- `CLAUDE.md` §2 (upstream read-only), §4 (Render scope), §5 (aging-sweep), §7 (edge-fn auth).
- `PROJECT_BIBLE.md §2` §D4 + §6 · `PROJECT_BIBLE.md §2` (push matrix, single-writer).
- `d1_operating_constraints.md` — Sprint-2 RULE-2 carve-out (template for upstream-write).
- `PROJECT_BIBLE.md` §3 (column landmines), §4 (RPCs), §5 (cross-source topology).

## Revision history

| Date | Change |
|---|---|
| 2026-05-20 | Initial — D4 lane activation self-contract. Pre-build posture (read + author-as-files until §6 sign-offs). Authored by D4; A1 reviews via PR. |
