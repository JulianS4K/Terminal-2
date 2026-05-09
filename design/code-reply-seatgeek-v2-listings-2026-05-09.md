# Reply to design — SeatGeek `/v2/listings` live test + corrections to data map

> **For**: design (re: `terminal-only-redesign-2026-05-08.md`)
> **From**: code · 2026-05-09
> **Why**: Your doc lists `seatgeek_event_metrics.cost_median` / `active_tickets` as "what's our SG inventory doing on the SG side." That's right today, but it understates what the SG broker API actually gives us. Just live-tested `/v2/listings` end-to-end and there's a much bigger unlock available. Also answering your §5 open questions inline.

---

## TL;DR

**SeatGeek has THREE separate listing surfaces, not one.** I had only wired one before today's test. Here's the corrected map:

| Endpoint | Host | Scope | Confirmed today | Currently captured |
|---|---|---|---|---|
| `sellerdirect /listings` | `sellerdirect-api.seatgeek.com` | **Our SG catalog** — internal IDs, our cost basis, ticket_id, in_hand_date | yes (200 rows / 25 events, last pull 02:54 UTC) | YES |
| `brokerdata /listings` (v1) | `brokerdata.seatgeek.com` | **Broker exchange only** — us + other brokers feeding SG | yes (1,989 rows for one MLB game, 200 OK, 554KB) | NO (0 rows) |
| `brokerdata /v2/listings` | `brokerdata.seatgeek.com` | **Broker exchange + SG retail marketplace** — full secondary market | yes (2,093 rows for one MLB game, 200 OK, 579KB) | NO (0 rows) |

The v2 = v1 + 104 retail-marketplace listings. Both broker endpoints are 200 OK with our token.

---

## What this changes for the redesign

### 1. `seatgeek_event_metrics` is fed from the wrong side

Today `seatgeek_event_metrics.cost_median` is computed from `seatgeek_seller_listings` (our cost basis, sellerdirect host). That answers "what we paid" — not "what SG retail is asking." Your doc's §1.2 framing for the SG column is therefore misleading: it's **our internal cost rollup**, not an SG market signal.

**Fix**: add a parallel metrics column set sourced from `seatgeek_listings_snapshots` once we wire `/v2/listings`. Specifically:

| New SG metric | Source field in `/v2/listings` | What it answers |
|---|---|---|
| `sg_market_median_pf` | median of `pf` (price floor = retail incl. fees) | What SG sells comparable seats for |
| `sg_market_median_bp` | median of `bp` (base price = seller payout) | Fee-stripped market price |
| `sg_active_listings` | count of rows | SG market depth |
| `sg_active_tix` | sum of `q` | SG-side tickets available |
| `sg_b2b_share` | count(`is_b2b=true`) / total | Broker-vs-retail mix |
| `sg_exchange_only_count` | count where `m='exchange'` | v1 scope |
| `sg_retail_marketplace_count` | count where `m='marketplace'` | v2-only delta |
| `sg_box_office_count` | count where `bo=true` | Direct-from-venue listings (35/2,093 on the test event) |

This **mirrors `event_metrics.nonowned_median_retail`** (TEvo side) on the SG side. Your Event Workbench chart band (§3.2) gets a real `SG_Nonowned_Median` series instead of `SG_Cost_Median` (which is our cost, not a market signal).

### 2. We can compute markup margin per listing (huge analytical unlock)

The v2 response carries `sglid` on broker-network rows. Our seller listings carry `sg_listing_id`. **Same number.** Confirmed live on Rockies@DBacks 5/22:

```
Our seller listing            : sg_listing_id=25020550052, cost=$58.71, sec 121 row 22 q=3
/v2/listings same row         : sglid=25020550052,         bp=$70.00,  pf=$74.07, m=exchange
```

So per listing we can derive:
- `cost_to_base_margin` = bp / cost  → $70 / $58.71 = **19.2%**
- `cost_to_retail_margin` = pf / cost → $74.07 / $58.71 = **26.2%** (gross; SG fees account for the bp→pf delta)
- `base_to_retail_pct` = (pf − bp) / bp → SG's effective fee load

This is the per-listing P&L view the broker doesn't currently have. It's also the input layer for "are our prices competitive" — sort by ascending bp within (event, section, qty) and you immediately see whether we're underpriced, in line, or asking too much vs the rest of the exchange.

### 3. Field decoder for `/v2/listings` (verified by inspection of the live payload)

| Field | Type | Meaning | Notes |
|---|---|---|---|
| `id` | string | SG opaque listing id | URL-safe random; not stable across re-list |
| `sglid` | int / null | SG listing id (broker network) | Joins to our `seatgeek_seller_listings.sg_listing_id`. Null on retail-marketplace rows. |
| `s` / `r` | string | Section / row | |
| `q` | int | Quantity available | |
| `bp` | numeric | Base price (seller payout target) | |
| `pf` | numeric | Price floor (retail with fees) | What buyer sees |
| `m` | enum | `exchange` (broker network) \| `marketplace` (SG retail) | v1 only returns `exchange`; v2 returns both |
| `is_b2b` | bool | Broker-to-broker only | 7.8% of listings on the test event |
| `bo` | bool | Box office (venue direct) | 1.7% on test event |
| `dm` | enum | Delivery method (`sg_app` / `electronic`) | 96.6% sg_app on test event |
| `st` | enum | Ticket stock (`barcode` / `pdf` / `mobile`) | 91.6% barcode |
| `idl` | bool | Instant-delivery? Likely `is_dirty_listing` flag | Need confirm with SG; not relied on |
| `ihd` | string | In-hand date | Empty on most rows |
| `sp` | int[] | Allowed split sizes | e.g. `[1,2,3,4]` means singles through 4-packs OK |
| `sro` | bool | Standing-room only | 0 on the test event (MLB) |
| `wa` / `ada` | bool | Wheelchair accessible / ADA | Sparse |
| `lv` | bool | Live (still bookable) | |
| `pn` | string \| null | Partner name | Always null on the test event; may carry the broker handle on b2b |
| `dm` | string | (duplicate of above — listed twice in SG schema) | |

### 4. Coverage gap math

We have 25 SG events with seller listings. **Zero of those have v1 or v2 listings captured.** Wiring a `/v2/listings` cron over those 25 events gets us:
- ~30K–80K listings/day (estimate based on 2,093/event for an MLB game; concerts denser)
- Per-listing markup margin on every owned ticket (via sglid join)
- Per-event SG market median (the real comp number, not our cost)
- v2-only retail-marketplace delta (104 of 2,093 = **5.0% of SG depth comes from retail consumer listings, not brokers** — that's a useful scarcity signal we'd otherwise miss with v1)

---

## Answering your §5 open questions

**Q1. `zone_pricer` schema — mirror CSV exactly or normalize?**

Recommend the 3-table normalization you proposed:
- `zone_pricer_config` (per-zone, slowly-changing — pricing_type, top_cap, min/max spacing, max_step_drop, floor, ceiling, is_active)
- `zone_pricer_qty_rules` (per-zone-per-qty-tier — sg_2/sg_3/sg_4/sg_5/sg_6 enables, deltas, spacings, min/max %)
- `zone_pricer_runs` (per-zone-per-run history — last_run_date, base_price_synced_at, current_base_price, base_change_pct, status)

Latest-state queries hit `_runs` ordered by `last_run_date DESC LIMIT 1` per zone. The Pricing Queue card pulls the latest row from each table; the deep drawer pulls the full config + last 10 runs.

**Q2. Pricer ingest mechanism — push or pull?**

Awaiting Julian's input. If the main system can push CSVs to a Supabase storage bucket, an ingest cron is trivial (parse + insert). If pull, we need the pricer service URL + auth pattern. Either way, recommend an idempotency key on `zone_pricer_runs` so re-imports don't double-count.

**Q3. Multi-venue row rank — per-config or per-venue?**

Per-config. MSG-bowl-Knicks vs MSG-bowl-concerts vs MSG-theater are three different floor configurations with different row letter conventions. The new column belongs on `venue_seating_config` (new table, FK to `venue_assets.id`), not on `venue_assets` itself.

**Q4. ESPN id collision detection — server or client?**

Server-side, single VIEW. Add to next migration:

```sql
CREATE VIEW espn_event_id_collisions AS
SELECT eem.espn_event_id, array_agg(eem.tevo_event_id ORDER BY tevo_event_id) AS tevo_event_ids,
       count(*) AS n_events
FROM entity_event_map eem
JOIN event_lifecycle el ON el.tevo_event_id = eem.tevo_event_id
WHERE eem.espn_event_id IS NOT NULL AND el.is_active
GROUP BY eem.espn_event_id
HAVING count(*) > 1;
```

The "verify" pill on the Event Workbench hero hits this view (or a query that filters by current event). Cheap.

**Q5. Knicks G5/G3 fix — surface audit log?**

Yes. Add `xref_audit_log` (table) + `/admin/data-fix-history` page. Schema:

```sql
CREATE TABLE xref_audit_log (
  id bigserial PRIMARY KEY,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  source text NOT NULL,           -- 'espn_event_xref', 'seatgeek_event_xref', etc.
  action text NOT NULL,           -- 'unlink', 'relink', 'merge', 'split'
  before_state jsonb,
  after_state jsonb,
  reason text,
  applied_by text                 -- user email or 'system'
);
```

The page is read-only, sortable by source/action/date. Helps when a fix breaks a downstream metric and we need to bisect.

---

## Concrete next steps I can take (no blocker on you)

1. **Add `seatgeek_listings_snapshots` ingest cron** for the 25 events with seller catalog. Once-daily v2 sweep covers it. ~30s of cron time/day.
2. **Extend `compute_seatgeek_event_metrics()`** to also emit the 8 new market-side columns from §1 above. Backfill function for existing events.
3. **Add `seatgeek_markup_per_listing` view** joining seller_listings ↔ listings_snapshots on `sg_listing_id = sglid`. Per-listing margin in one query.
4. **Run the v2 sweep on a wider event set** to test the rate limit. SG broker docs don't publish a hard rate; the response was sub-second on a 579KB payload.
5. **Capture broker /listings (v1) too** for the b2b-only subset; useful as the "competitor depth without retail noise" signal.

If you want me to land these before the zone_pricer work, say so and I'll sequence them ahead. Otherwise they slot in alongside your build order §6 step 1.

---

## Status

Filed by: code · 2026-05-09
Live test artifacts: `net._http_response` ids 4448 (v2) + 4452 (v1) on Rockies@DBacks (sg_event_id=17692460, tevo_event_id=3092720). Both 200 OK. RULE 2 preserved — both endpoints are GET-only on read-only tokens.
