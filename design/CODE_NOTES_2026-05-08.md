# Code notes — backend hooks the design skeletons assume (2026-05-08)

> **Audience**: Julian (code) — read this top-to-bottom to know exactly what backend
> work each design skeleton needs. Frontend is done; backend is yours.
>
> **Rule**: design touched ONLY `static/_proposals/*.html` and `design/*.md` this session.
> Zero changes to `app.py`, edge functions, migrations, or `SCHEMA.md`.
>
> **Files added by design (frontend skeletons)**:
> - `static/_proposals/templates.html` — broker terminal · 6 templates · hash-router
> - `static/_proposals/shop.html` — retail buying site · 4 views (catalog/event/cart/account)
> - `static/_proposals/undelivered.html` — fulfillment ops board
>
> **Companion design docs** (already filed, all in `design/`):
> - `preliminary-event-views-2026-05-08.md` — 6 broker templates, structural decisions, simulation grid
> - `retail-site-2026-05-08.md` — retail product, wall enforcement, telemetry
> - `undelivered-window-2026-05-08.md` — fulfillment ops design

---

## 0. Worktree state at hand-off

- HEAD = `3d55a38` (origin/main tip; mig 20260509140000 included)
- Branch: `claude/mystifying-lederberg-ea407b`
- Local main checkout was 40 behind origin/main (stale); worktree itself is fully current
- BLOCKED row in KANBAN: chart-range-switcher edits in `static/index.html` from earlier in this session — separate from this design work

---

## 1. Broker terminal (`static/_proposals/templates.html`) — backend needs

### 1.1 Existing endpoints — wired in skeleton

These already exist and are referenced:

| Endpoint | Used by | Notes |
|---|---|---|
| `GET /api/broker/event/{id}/overview` | T1 hero data | existing |
| `GET /api/broker/event/{id}/chart-data?range=` | T1 chart | existing |
| `GET /api/broker/event/{id}/zones` | T1 zone breakdown | existing |
| `GET /api/broker/event/{id}/orders` | T1 order book strip | existing — but skeleton renders canonical state counts directly, see §1.2 |
| `GET /api/broker/event/{id}/espn` | T1 + T2 ESPN block | existing; gate on `entity_event_map.espn_*` not null |
| `GET /api/broker/performer/{id}/espn` | T2 ESPN context | existing |
| `GET /api/portfolio?performer_id=` | T2 (legacy) | existing — replace with §1.2 endpoint when ready |

### 1.2 NEW endpoints — wire these on the backend

| Endpoint | Purpose | Underlying | Priority |
|---|---|---|---|
| `GET /api/broker/event/{id}/owned-premium` | T1 headline KPI | DERIVE: `(owned_median_retail - nonowned_median_retail) / nonowned_median_retail` from `event_metrics`. No new ingest. | **P1** — biggest visual on T1, easy to ship. |
| `GET /api/broker/event/{id}/sentiment` | T1 sentiment ribbon + score | `event_sentiment` table from mig 20260509130000. Return latest snapshot + 7d series for the ribbon. | **P1** |
| `GET /api/broker/event/{id}/similar?n=5` | T1 comparable matchups | call `find_similar_events(event_id, 5)` SQL function from mig 20260509130000. | **P1** |
| `GET /api/broker/event/{id}/competing-metro` | T1 competing strip + T5 slate | filter by `metro_id` JOIN on `events` + same-day window. Needs §1.4 metro_id seed. | **P2** |
| `GET /api/broker/performers/{id}/detail` | T2 rollup | rollup over `events WHERE primary_performer_id=$1`. Reuse `/api/portfolio?performer_id=` shape if cleanest, just rename. | **P1** |
| `GET /api/broker/performers/{id}/baseline` | T2 baseline strip | read from `performer_baselines` table (mig 20260509130000). | **P1** |
| `GET /api/broker/performers/{id}/history?n=5` | T2 last-5 comparable home games | use the same matchup-similarity logic as `find_similar_events` but filtered to `is_home=true`. | **P1** |
| `GET /api/broker/venues/{id}/baseline` | T3 KPIs | read from `venue_baselines` table (mig 20260509130000). | **P2** |
| `GET /api/broker/venues/{id}/section-curve?mode=` | T3 section premium curve | aggregate `section_metrics` filtered by `event_type` for the active mode tab. | **P2** |
| `GET /api/broker/venues/{id}/events?mode=&days=` | T3 upcoming list | `events WHERE venue_id=$1 AND event_type=$2 AND occurs_at_local BETWEEN now AND now+$3d`. | **P2** |
| `GET /api/broker/series/{series_id}/timeline` | T6 series mode | derived from `events.name LIKE '%Game N%'` + matchup grouping. Recommend a `series_xref` table seeded from ESPN bracket data. | **P3** — fallback works without it via current data. |
| `GET /api/broker/performers/{id}/season/{year}` | T6 season mode | aggregate `events WHERE primary_performer_id=$1 AND season_year=$2 AND is_home=true`. | **P3** |
| `GET /api/broker/tours/{tour_id}/stops` | T6 tour mode | needs `tour_metadata` table — currently a data hole. Without it, parse `events.name` for tour clues. | **P3** — partially data-blocked. |
| `GET /api/broker/metro/{metro_id}/slate?date=&type=` | T5 main view | filter events by metro_id + date + optional event_type. | **P2** |
| `POST /api/broker/pricing-queue/{filter_hash}/start` | T4 entry | new table `pricing_queue_state(user_id, filter_hash, current_event_id, suggested_asks_jsonb, last_seen_at)`. | **P2** |
| `POST /api/broker/pricing-queue/{filter_hash}/save` | T4 save & advance | upsert suggested_asks JSON, advance cursor. | **P2** |
| `GET /api/broker/pricing-queue/{filter_hash}/advance` | T4 next event | next event in filter set, ordered by `(occurs_at_local ASC, event_id)`. | **P2** |
| `GET /api/broker/analysis/{scope}/{id}` | LLM auto-analysis (Grok hookup) | wraps Grok / Claude / configurable model. Server-side prompt template. Cache 5 min per (scope, id). Recompute on owned_share or sentiment delta > 5pts. | **P3** — placeholder slots already in skeleton; ship when LLM strategy is firm. |

### 1.3 Order book panel on T1 — uses canonical states (mig 20260509140000)

The skeleton renders 6 buckets: `pending / accepted / substitution / rejected / cancelled / fulfilled` directly from `unified_orders_by_event WHERE tevo_event_id = $1`. This is per the canonical state model code shipped in `20260509140000_order_status_canonical.sql`. No new endpoint needed if `/api/broker/event/{id}/overview` is extended to include this aggregation, OR add a thin `/api/broker/event/{id}/order-status` endpoint.

### 1.4 Metro id lookup — small new table needed

T1 competing strip + T5 metro view both need a notion of "metro" that doesn't exist in the schema today.

```sql
-- Suggested:
CREATE TABLE metro_id_lookup (
  metro_id text PRIMARY KEY,         -- 'nyc', 'la', 'chi', ...
  display_name text NOT NULL,
  geohash_p3 text NOT NULL,          -- coarse fallback for the long tail
  bbox_lat_min numeric, bbox_lat_max numeric,
  bbox_lng_min numeric, bbox_lng_max numeric
);

-- Top 20 markets seeded manually. Long tail uses geohash-precision-3.
-- Per-event lookup: events.metro_id is computed at insert via venue.lat/lng
-- against bbox/geohash.
```

The skeleton expects `events.metro_id` to exist. Could be a generated column or a backfilled regular column.

---

## 2. Retail site (`static/_proposals/shop.html`) — backend needs

### 2.1 Wall enforcement (NON-NEGOTIABLE)

Per `design/retail-site-2026-05-08.md` §1.1, retail reads from a SINGLE view that filters to S4K-owned + retail-eligible. The view is the wall:

```sql
CREATE VIEW public.retail_inventory_v AS
SELECT
  l.listing_id, l.event_id, l.section, l.row, l.quantity, l.retail_price,
  e.name AS event_name, e.occurs_at_local, e.venue_id, e.event_type,
  e.primary_performer_id, e.tour_name
FROM listings_snapshots l
JOIN events e ON e.id = l.event_id
WHERE l.is_s4k_owned = true              -- WALL
  AND l.retail_visible = true            -- WALL
  AND l.is_active = true
  AND l.expires_at > now()
  AND e.occurs_at_local > now();
```

`/api/retail/*` handlers MUST read only from `retail_inventory_v` (and a small set of derived views like `retail_events_v` for the catalog page). They MUST NOT read directly from `listings_snapshots` or any source table. Audit recommendation: a CI test that hits `/api/retail/*` against a synthetic dataset where some rows are wholesale-flagged, asserts they don't leak.

### 2.2 NEW endpoints

| Endpoint | Purpose | Notes |
|---|---|---|
| `GET /api/retail/events/featured?metro=` | Tonight Near You | reads `retail_events_v` filtered by date + metro |
| `GET /api/retail/events/search?q=&city=&date=&genre=&min_qty=` | Search results | full-text + facets, S4K-only |
| `GET /api/retail/events/{id}` | Event detail | metadata only, no analytics, no premium, no ownership |
| `GET /api/retail/events/{id}/inventory?section=&min_qty=` | Listing rows on event detail | S4K-only |
| `GET /api/retail/events/{id}/sections` | Section + price-range overview | for the section table |
| `GET /api/retail/venues/{id}/map` | Venue seat-map asset URL | when `venue_assets.has_map=true` |
| `GET /api/retail/categories` | Top genres for nav | static list OK for v1 |
| `POST /api/retail/cart` | Cart create / update | new `retail_carts` table |
| `POST /api/retail/checkout/session` | Stripe Checkout session | redirects to Stripe |
| `POST /api/retail/chat` | Chatbot turn (reuses /chat backend) | writes a turn to `retail_events`; response includes optional `deep_link` for view-tickets handoff |

### 2.3 Telemetry — chatbot training corpus

Per `design/retail-site-2026-05-08.md` §3, every meaningful action writes to `retail_events`:

```sql
CREATE TABLE retail_events (
  id bigserial PRIMARY KEY,
  ts timestamptz NOT NULL DEFAULT now(),
  event_type text NOT NULL,             -- 'search' | 'event_view' | 'section_focus' | 'add_to_cart' | 'cart_abandon' | 'purchase' | 'chat_turn' | 'chat_to_event'
  user_id uuid,                          -- nullable; anonymous OK
  session_id text NOT NULL,             -- always present
  payload jsonb NOT NULL                 -- event_type-specific fields
);
CREATE INDEX idx_retail_events_session ON retail_events(session_id, ts);
CREATE INDEX idx_retail_events_user ON retail_events(user_id, ts) WHERE user_id IS NOT NULL;
CREATE INDEX idx_retail_events_type ON retail_events(event_type, ts);
```

The skeleton calls a JS `track()` helper (TODO note in shop.html) that wraps `POST /api/retail/track`. **Capture from day-1 even if the training pipeline isn't built yet** — we want the corpus to exist when we need it.

### 2.4 Stripe wiring

Existing Stripe Checkout code in `app.py` works for the broker terminal — confirm whether a separate retail Stripe account is needed (likely yes for tax + receipt branding) or if the same account with metadata works.

---

## 3. Undelivered window (`static/_proposals/undelivered.html`) — backend needs

### 3.1 Source view — already exists (mig 20260509140000)

Skeleton uses `unified_orders` directly. "Undelivered" = `NOT is_terminal AND tevo_event_id IS NOT NULL` (i.e., canonical_status IN `pending`, `accepted`, `substitution`).

`unified_orders_by_event` is already perfect for the bulk-action grouping logic.

### 3.2 NEW endpoints

| Endpoint | Purpose | Underlying |
|---|---|---|
| `GET /api/broker/undelivered?window=&channel=&state=&min_gross=&q=&cursor=` | Main board rows | `SELECT * FROM unified_orders WHERE NOT is_terminal AND tevo_event_id IS NOT NULL ORDER BY occurs_at_local ASC` filtered by query params |
| `GET /api/broker/undelivered/kpi` | Top KPI strip | aggregate counts + sum(gross) over the same view |
| `GET /api/broker/undelivered/holds-expiring?within=4h` | Hold-expiry lane | filter on `hold_expires_at < now() + interval '4h' AND NOT is_terminal` — note: `hold_expires_at` exists on `evo_orders` but not on the unified view yet; add it via the UNION ALL clauses or a sister view |
| `GET /api/broker/undelivered/{order_id}/timeline` | Drawer timeline | per-order audit log; needs `order_audit_log` table (proposed; `state`, `actor`, `note`, `ts`) |
| `POST /api/broker/undelivered/{order_id}/deliver` | Per-order action | server-side dispatcher to channel-appropriate API |
| `POST /api/broker/undelivered/event/{event_id}/bulk-deliver` | Bulk action | server-side job that processes all undelivered orders for an event; returns a `job_id` for progress polling |
| `GET /api/broker/jobs/{job_id}` | Job progress | `(state, total, succeeded, failed)` |

### 3.3 Hold-expiry alarm cron

Recommend a 5-min cron that finds `hold_expires_at < now() + interval '30min'` and fires a Slack/PagerDuty alert. Out of scope for this UI but relevant context — the skeleton's alert banner is reactive; the proactive layer is server-side.

### 3.4 Missing column — `hold_expires_at` on unified view

`unified_orders` doesn't currently expose `hold_expires_at` (it's on `evo_orders` only). Suggest adding it to the UNION ALL with NULL for sources that don't have it — most actionable on EVO + SG (where holds matter).

---

## 4. Frontend conventions established (for whoever picks this up)

These conventions are baked into all three skeletons; honor them in subsequent edits.

- **CSS variables** match `static/index.html`. Lifted into each skeleton head as a self-contained block so the file works standalone in preview.
- **TODO markers**: every backend hook is marked with `<span class="todo">/api/...</span>`. Visually orange, tagged "todo". Easy to grep for `class="todo"` to find them.
- **Hash-routing**: `templates.html` and `shop.html` both use hash-routing for sub-views (no React Router; just `location.hash`).
- **No React, no bundler, no npm**. Vanilla JS, Chart.js loaded from CDN if and when used. Per code's redesign memo §6: "single file, vanilla JS only, CSS variables for theming."
- **localStorage versioning**: any persisted UI state uses `key_v1` / `key_v2` so defaults can shift without breaking existing users.
- **Strict wall**:
  - `templates.html` and `undelivered.html` are broker-only. They reference `/api/broker/*`.
  - `shop.html` is retail-only. It references `/api/retail/*`. The skeleton has a comment header forbidding `/api/broker/*` references — grep guard.

---

## 5. Wiring sequence (suggested)

To minimize churn, ship in this order:

| # | Ship | Skeleton it powers | Effort |
|---|---|---|---|
| 1 | `/api/broker/event/{id}/owned-premium` (derive) | T1 headline KPI | trivial |
| 2 | `/api/broker/event/{id}/sentiment` reading `event_sentiment` | T1 ribbon | small |
| 3 | `/api/broker/event/{id}/similar?n=5` | T1 comparables strip | small |
| 4 | `/api/broker/performers/{id}/{detail,baseline,history}` | T2 | medium |
| 5 | Order-status canonical buckets on T1 (existing view, just expose) | T1 order book strip | small |
| 6 | `/api/broker/undelivered/*` endpoints + KPI | undelivered window | medium |
| 7 | `/api/broker/undelivered/event/{id}/bulk-deliver` server job | undelivered bulk action | larger |
| 8 | `metro_id_lookup` seed + `/api/broker/metro/*` | T5 + T1 competing strip | medium |
| 9 | `retail_inventory_v` view + `/api/retail/*` namespace | shop.html v1 | larger |
| 10 | `retail_events` telemetry + tracker | shop.html telemetry | medium |
| 11 | Pricing-queue state table + endpoints | T4 | larger |
| 12 | `/api/broker/analysis/*` Grok wrapper | LLM slots across all templates | medium-larger |

---

## 6. Open questions for code (please decide)

1. **Audit pass coverage**. Does the audit pass already check that `/api/retail/*` doesn't expose wholesale? If not, recommend adding it before the retail surface goes live.
2. **`hold_expires_at` on unified view**. Add to mig as a follow-up (`hold_expires_at` NULL-able, populated for EVO + SG)?
3. **`series_xref` table or NLP parsing on `events.name`**? Suggest the table — cheaper to maintain over time and the seed is small (current 7-game series in our system are countable on one hand).
4. **`tour_metadata` source**. MusicBrainz vs Bandsintown vs manual seed for top tours? Out of scope this session; flag for next planning.
5. **Pricing-queue write path**. Doc says read-only v1 (writes "suggested ask" to our DB; CSV export to push to TEvo). Confirm this scoping before designing the bulk-export.
6. **Retail Stripe account**. Same account as broker (with metadata) or separate? Affects checkout wiring.
7. **`/shop` route mounting**. Same Railway service via `/shop` mount, or separate service? Doc recommends same service for v1 (shared bootstrap, single SSL).

---

## 7. Status

- 3 frontend skeletons on disk, ready to preview by opening `static/_proposals/*.html` in a browser.
- 3 design docs (the strategy + simulation work) already filed and KANBAN-tracked.
- 0 backend changes by design this session.
- 0 pushes (per the wall rule).

Read top-to-bottom; ping back when you want to pair on prioritization.
