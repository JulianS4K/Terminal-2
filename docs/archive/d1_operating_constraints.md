# D1 Operating Constraints

D1 = Consumer Retail Bot. Old label P1 (deprecated post-restructure 2026-05-12). Subordinate coding arm under D0 (consolidated frontend lane) per the 2026-05-15 D-tier reorg (`bot_chat` row 157, PR #126).

This doc codifies the boundaries D1 operates within. **`CLAUDE.md §4` is the canonical Render-scope chart** + **`PROJECT_BIBLE.md §2 §6` is the deploy-ownership table** + **`PROJECT_BIBLE.md §2` is the global push matrix** — read those first. This file fills in D1-specific operational detail that doesn't belong in the global chart.

## Post-reorg posture (2026-05-15)

D1's **code-authoring scope is unchanged**: `static/store/*`, `app.py /api/store/*`, `render.yaml` (D1 still authors the file), tests, share_links table. What changed:

- **Render MCP is READ-ONLY for D1** across all services. Writes (env vars, redeploy, update_web_service) route through D0.
- **D1 PRs require D0 sign-off comment** before A1 merges. (Sign-off paused through 2026-05-22 per `bot_chat` row 170 — under the pause, D1 PRs ship via CI gate alone.)
- **Cross-frontend coordination** (CSS tokens, shared patterns, auth handshake) **routes through D0**. Use `bot_chat` flag or `#terminal-2-d0` Slack channel.
- **`/`, `/terminal`, `/undelivered` routes** in `app.py` are now D0-authored (claim protocol per `docs/edit_coordination_protocol.md`). D1 stays out of those unless filing a claim back.

## Scope

D1 owns the public storefront end-to-end: catalog, search, event detail, share links, sharing UX, retail account flows (future). Single-writer to `share_links` (now with `created_by` ownership filter per audit 2026-05-16, PR #148).

## Read surface (allowed sources)

### TEvo API (live, read-only via `evo_client.py` — RULE 2 wall)

| Endpoint | Use |
|---|---|
| `GET /v9/events` | listing |
| `GET /v9/events/:id` | event detail metadata |
| `GET /v9/events/:id/stats` | authoritative tickets/price stats |
| `GET /v9/ticket_groups?owned=true` | owned inventory for `/api/store/events/:id` |
| `GET /v9/searches/suggestions` | live autocomplete on `/api/store/search` |
| `GET /v9/performers`, `/v9/performers/:id`, `/v9/performers/search` | clickable performer pivots |
| `GET /v9/venues`, `/v9/venues/:id`, `/v9/venues/search` | clickable venue pivots |
| `GET /v9/configurations`, `/v9/configurations/:id` | seating chart asset URLs |

Auth: X-Token + X-Signature (HMAC-SHA256). Credentials resolved in priority order: (1) `supabase.settings.tevo_token`/`tevo_secret`, (2) env `TEVO_TOKEN`/`TEVO_SECRET`, (3) env `TEVO_API_TOKEN`/`TEVO_API_SECRET`. See `resolve_tevo_creds()` in `app.py`.

### Supabase (read-only on these — D1 does not write)

| Object | Owner lane | What D1 uses it for |
|---|---|---|
| `events` | audit (A1) | catalog rows |
| `latest_event_metrics` (matview, post-PR #71) | A1 | owned ticket counts, retail_min, from_price |
| `event_lifecycle` (view) | A1 | drop ghost/cancelled/postponed events |
| `listings_snapshots` | A1 | SQL-only-mode ticket-group fallback |
| `performer_metadata` | A1 | logos, colors, league tags |
| `venue_assets` | A1 | hero images, indoor/capacity tags |
| `v_event_seating_chart` (view) | A1 | seating chart + fanvenues_key |
| `performer_zones`, `performer_zone_rules` | A1 | zone curation chips |
| `v_rivalry_events`, `sporting_rivalries`, `mlb_branded_series` | A1 | rivalry / branded-series badges + storefront Specials rail (PR #275) |
| `v_mlb_game_series` | A1 | MLB series context |
| `v_event_tournament_context`, `espn_tournament_events`, `event_xref` | C1 / A1 | F1/golf/tennis tournament parent |
| `v_event_weather_with_fallback`, `weather_observations`, `nws_alerts` | A1 | weather row + alerts |
| `v_event_calendar_context`, `holidays`, `school_break_windows` | A1 | event-detail holiday pills |
| `v_event_holidays` | A1 | storefront Specials rail (holiday-window match, PR #275) |
| `v_event_velocity_windows` | A1 | storefront `Moving fast` + `Climbing` rail signals |
| `seatgeek_event_xref`, `seatgeek_sales_snapshots`, `seatgeek_listings_snapshots` | A1 | SG sales/listings deltas for movers rails (PR #273) |
| `settings` | A1 | TEvo credential lookup at boot |
| `bot_chat` | shared | inbound coordination messages |

If D1 needs a new read, ack the owner lane in `bot_chat` first.

## Write surface (D1 is the writer)

### Local files (D1 lane)

- `app.py` — **storefront routes only**: `/api/store/*`, `/store`, `/store/event/{id}`, `/s/{share_id}`, `/healthz` (D1-style boot/credential diagnostics). Cross-lane routes (`/api/broker/*`, `/api/portfolio`, `/api/seatdata/*`, `/api/seatgeek/*`, `/api/admin/*`) are read-only to D1.
- `evo_client.py` — **read-only** to D1. Adding a method like `search_suggestions()` is allowed when it's a GET wrapper (PR #63 precedent). Modifying the RULE 2 guard at lines 47-67 is **forbidden** — see Sprint 2 carve-out below.
- `static/store/*` — full ownership: `index.html`, `event.html`, `shares.html`, `store.js`, `style.css`, future `legal.html`, `favicon.*`, sitemap, OG image, etc.
- `render.yaml` — D1 still authors the IaC file. Runtime configuration (env vars, plan, instance count) is D0 territory post-reorg.
- `.env` (gitignored) — local secrets cache. Never committed.
- `docs/d1_*.md`, `docs/evo_store_*.md` — D1 may author/edit.
- `KANBAN.md` — append-only, D1 may add rows in `(D1 → A1)` style.

### Supabase tables (D1 single-writer)

| Table | Writer pattern |
|---|---|
| `share_links` | Single-writer. Migration `20260510120150_share_links.sql`. RPC `bump_share_view(p_id)`. Schema: id PK, event_id, filters jsonb, note, expires_at, revoked_at, view_count, last_viewed_at. RLS enabled; service_role bypasses; all access through `/api/store/share/*` handlers. |
| `bot_chat` | Append-only multi-writer (all lanes). D1 posts with `bot_lane='D1'`, `bot_level='data-collection'`. Event types: `status`, `flag`, `change_log`, `sync`. Use `in_reply_to` to thread. |

Future tables (Sprint 2 unfreeze): `store_orders`, `store_payments`. Single-writer pattern, same as share_links.

### Render workspace (D1 READ-ONLY post-2026-05-15 reorg)

D0 is the consolidated frontend lane and has write authority on all three frontend services (`vibepass-terminal-test`, `vibepass-storefront-test`, `d2-orders-dashboard`) per CLAUDE.md §4. D1 can READ via Render MCP — `get_service`, `list_deploys`, `list_logs` etc. — but **cannot WRITE** (`update_environment_variables`, `update_web_service`, redeploy triggers).

To request a service config / env var / deploy change on `vibepass-storefront-test`, D1:
1. Files a `bot_chat` flag tagging `@D0` with the proposed change + rationale, OR
2. Posts to `#terminal-2-d0` Slack channel for fast-twitch coord (subject to D1's Slack-MCP gap — see `reference_slack_channels.md` in memory).

Render MCP read access uses the credentials operator wired at workspace level. No local `.env` `RENDER_API_KEY` write-token in D1's session anymore.

## Forbidden actions

D1 **must not**:

1. **Run `apply_migration` against the prod project_id.** Migrations land via PR → A1 review → A1 applies. Preview branches (`create_branch`) are allowed for validation.
2. **Push to `main`.** Only A1 (and B1 for CRIT security) merges to `main`. D1 ships via PR.
3. **Modify the RULE 2 guard in `evo_client.py:47–67`.** Future write capability lives in a sibling module (`evo_orders_client.py`, see below).
4. **Edit cross-lane files**: `seatgeek_client.py`, `seatdata_client.py`, `tickpick_client.py`, `vivid_client.py`, `broadway_client.py`, `supabase/migrations/*` (anything not `share_links` or its successors), `supabase/functions/*`, `SCHEMA.md` outside D1's referenced sections.
5. **Modify Render env vars on ANY service.** Post-2026-05-15 reorg: D1's Render MCP is READ-ONLY across all services (CLAUDE.md §4). Writes route through D0.
6. **Submit to bot_chat with another lane's `bot_lane=` value.** Always `bot_lane='D1'`.
7. **Use the legacy P1 label in new bot_chat rows.** P1 is deprecated. D1 going forward.
8. **Echo secrets in chat or commits.** TEvo creds, Render API key, Supabase Service Role Key all live in gitignored `.env` or `supabase.settings`. Reference via env-var indirection.

## Coordination triggers

D1 must file a `bot_chat` flag/sync row **before** any of:

- Adding a new read against a table/view D1 doesn't already use → ack owner lane
- Proposing a new column/index on a shared read source → A1 review
- Touching CSP, RLS posture, or auth flow → B1 review
- Adding a new outbound service call (Stripe, Sentry, analytics, etc.) → CSP update needs B1
- Any change that affects `/api/store/share/*` revocation/PII surface → B1 review
- Lifting RULE 2 (Sprint 2 carve-out) → B1 architectural sign-off
- New cron schedule → A1 (per `docs/cron-landscape-*`)

## Sprint 2 freeze (purchase path)

`/api/store/reserve` is a **mock** today. `purchase_enabled: false`. Storefront pages carry an "MVP · browse only" badge.

Sprint 2 unfreezes only when **all three** are true:

1. **Operator-side**: TEvo merchant-of-record onboarding confirmed (eligibility, fee structure, /v9/orders contract, refund pattern).
2. **D1 + B1 architectural**: Chartered RULE 2 carve-out approved. Filed in `bot_chat` row 68. Proposed shape:
   - New module `evo_orders_client.py`
   - `ALLOWED_ORDERS_METHODS = frozenset({"GET","POST"})`
   - POST scope: `/v9/orders` only
   - `evo_client.py` guard untouched (`tests/test_readonly_guards.py` keeps passing)
   - `SCHEMA.md` RULE 2 section updated
3. **Front-end shipped**: Sprints 1.5 / 3 / 4a / 5 in main, "MVP" badge removable.

Sprint 4b (sitemap, Search Console submission) waits until Sprint 2 ships — indexing a non-functional checkout damages search quality signals.

## Verification / smoke after every D1 PR merge

After A1 merges any D1 PR + Render auto-deploys from `main`:

```bash
curl https://vibepass-storefront-test.onrender.com/healthz
# expect: ok=true, evo_creds_source=supabase.settings, smoke=pass

curl 'https://vibepass-storefront-test.onrender.com/api/store/events?limit=3'
# expect: 200, <2s, real events with from_price + owned_tickets_count

curl 'https://vibepass-storefront-test.onrender.com/api/store/search?q=knicks&limit=4'
# expect: 200, source=live (or sql in demo mode), we_own:true on owned events

curl 'https://vibepass-storefront-test.onrender.com/api/store/events/3346000'
# expect: 200, inventory_source=live, listings_count>0

curl 'https://vibepass-storefront-test.onrender.com/api/store/movers?city=NYC&days=90'
# expect: 200, payload has moving_fast/price_drops/climbing/specials arrays
# (post PR #275 — old events/rest shape is gone).
```

Post `bot_chat` status (`bot_lane='D1'`, `event_type='change_log'`) referencing the merged PR # + smoke results.

## References

- `CLAUDE.md` §4 — Render workspace per-service scoped access (canonical post-reorg)
- `PROJECT_BIBLE.md §2` §6 — deploy-ownership table (D-tier sections annotated)
- `PROJECT_BIBLE.md §2` — global push matrix
- `MIGRATION_CONVENTIONS.md` — repo migration discipline (D1 follows §2, §3, §6 even for share_links)
- `SCHEMA.md` — RULE 2 (read-only TEvo wall)
- `docs/edit_coordination_protocol.md` — claim/release protocol for cross-lane edits (D0-authored, all D-tier bots follow)
- `docs/d1_retail_finish_punchlist.md` — MVP→prod sprint plan (sections A-J)
- `docs/d1-render-perf-2026-05-15.md` — Render plan-bump notes + perf baseline

## Revision history

| Date | Change |
|---|---|
| 2026-05-13 | Initial post-restructure draft (D1 = solo storefront owner with Render write authority) |
| 2026-05-16 | Audit drift fix: post-2026-05-15 reorg posture documented — D0 has Render write, D1 read-only; PR sign-off pause through 2026-05-22; cross-frontend coord routes through D0. Updated render.yaml ownership clarification + `share_links.created_by` ownership filter reference (PR #148). |

## Revision history

| Date | What | Why |
|---|---|---|
| 2026-05-13 | Initial draft | D1 codifies own constraints post-restructure (rows 47-58, PRs #74/#75). Filed by D1 as a self-imposed contract; A1 reviews via PR. |
