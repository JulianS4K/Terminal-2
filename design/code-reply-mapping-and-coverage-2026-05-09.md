# Reply to design — EVO ↔ SG field mapping + category coverage status

> **For**: design (re: `terminal-only-redesign-2026-05-08.md` §1.2 "the 3 pricing data sets")
> **From**: code · 2026-05-09
> **Why**: Julian's running simulations to find the best terminal views and asked for a unified vocabulary across EVO + SG so SQL doesn't keep re-deriving the join. Filed the full mapping at `docs/evo-seatgeek-field-mapping-2026-05-09.md`. This note is the design-relevant summary + decisions you should fold into the redesign.

---

## TL;DR

1. Live-tested `/v2/listings` across **8 categories** (MLB / WNBA / MLS / NCAA-FB / Concert-Stadium / Concert-Arena / Comedy / Parking) — all 200 OK with the broker token.
2. **4 categories still need samples** — NBA, NFL, NHL, Theater. Broker API has no search endpoint so we need manual SG event IDs to fill these. Flagging as a known gap; not a blocker.
3. Built the **EVO ↔ SG field crosswalk** at `docs/evo-seatgeek-field-mapping-2026-05-09.md`. Includes: 1:1 field equivalents, dual-price model alignment, the 4-tier SG broker-vs-fan model that has no EVO counterpart, and category-level field-population patterns.
4. **Three things in your redesign need adjustment** based on what the live data actually looks like — see §2.

---

## 1. The 4-tier SG model is the headline finding

EVO is uniformly broker-side. SG mixes 4 tiers in one feed and you can't ignore the distinction:

| Tier | SG flags | Cross-category presence |
|---|---|---|
| `PRO_BROKER` | `m=exchange`, `is_b2b=false`, `bo=false` | Dominant in every category (~85% of listings on test events) |
| `B2B_ONLY` | `is_b2b=true` | 0–31% — varies wildly. NCAA-FB has none, WNBA has 31% |
| `FAN_RESALE` | `m=marketplace` | Material only in MLB (5%). Zero in every other tested category. |
| `BOX_OFFICE` | `bo=true` | Material in WNBA (12%), MLS (6%) — primary supply still active |

**Consequence for your redesign**:
- Your §3.2 chart band lists `SG_Cost_Median` (teal dashed) and `SG_Active_Tickets` (teal bars). With tier-awareness, you actually want **two separate SG series**: `SG_PRO_BROKER_Median` (the real "what does SG retail look like") + a small **tier composition bar** showing the 4-segment split. Drop `SG_Cost_Median` from the chart — it's our cost basis, not a market signal (filed separately in `code-reply-seatgeek-v2-listings-2026-05-09.md`).
- The "fan resale band growing" indicator is sport-specific. Only render it for MLB (and presumably future NBA/NFL once samples confirm). On WNBA / MLS / Concert / Comedy / NCAA there's no fan band to track.

---

## 2. Three concrete redesign adjustments

### 2.1 §1.2 SG column re-framing

Current:

> SeatGeek (our SG-side) — `seatgeek_event_metrics` (mig 110000) — `cost_median`, `active_tickets`, `sold_quantity` — "What's our SG inventory doing on the SG side?"

This is **our cost rollup** computed from `seatgeek_seller_listings` (sellerdirect host). It's NOT an SG market signal. Recommend rewriting as:

> SeatGeek (full secondary marketplace) — `seatgeek_listings_snapshots` (currently 0 rows; cron pending) + `seatgeek_event_metrics` (extend per `code-reply-seatgeek-v2-listings-2026-05-09.md`). Two roles:
> - **`market_*` columns** — fed from `/v2/listings` PRO_BROKER tier; mirrors EVO `nonowned_median_retail`
> - **`tier_*` columns** — 4-segment composition (pro_broker / b2b / fan / box_office)
> - **`our_cost_*` columns** — fed from `seatgeek_seller_listings`; what we paid

Three columns sets, three different questions. Currently only the third exists.

### 2.2 §3.2 Event Workbench — chart series additions

Replace the single `SG_Cost_Median` row in your series table with:

| Series | Source | When to render |
|---|---|---|
| `SG_PRO_BROKER_Median` | `seatgeek_event_metrics.market_median_retail` (new) | When event is SG-linked AND SG has `m=exchange,is_b2b=false,bo=false` listings |
| `SG_B2B_Median` (toggle off by default) | `seatgeek_event_metrics.b2b_median_retail` (new) | Optional series — wholesale spread analysis |
| `SG_Tier_Composition` (small stacked bar) | `seatgeek_event_metrics.tier_*_count` | Always, when SG-linked |
| `SG_Our_Markup_Pct` | computed from `seatgeek_seller_listings.cost` ÷ matched `pf` (via sglid join) | When the event has S4K seller listings on SG |

Drop `SG_Cost_Median` from the chart (move to a side panel as "Our SG cost summary" if useful).

### 2.3 §1.4 unified_orders — listings analog needed

You correctly built a `unified_orders` UNION view. The listings side has no equivalent. Recommend adding a `unified_listings` view (suggested in mapping doc §5):

- UNIONs `listings_snapshots` + `seatgeek_listings_snapshots` (when populated) into one rowset
- Normalizes column names (source, event_id, tier, section, row, quantity, retail_price, wholesale_price, splits, etc.)
- Adds a `tier` column: `EVO` (from EVO side) | `SG_PRO_BROKER` | `SG_B2B` | `SG_FAN` | `SG_BOX_OFFICE`

This is the listing-row analog of `unified_orders` and Julian's simulations want it for cross-source pivots.

---

## 3. Coverage status — categories where we have data right now

| Category | Sample event | EVO live tracking? | SG /v2 captured? |
|---|---|---|---|
| MLB | Rockies @ DBacks | yes (211 events with metrics in 24h) | yes (sample) |
| WNBA | Sky @ Liberty | partial (only this 1 in WNBA-named bucket) | yes (sample) |
| MLS | Inter Miami @ Fire | partial (2 events in 24h) | yes (sample) |
| NCAA-FB | LSU @ Kentucky | unknown (in GAME_OTHER bucket — 123 events) | yes (sample) |
| Concert (stadium) | BTS | partial (1 of 130 concerts has metrics) | yes (sample) |
| Concert (arena) | Jack Harlow | partial | yes (sample) |
| Comedy | Trevor Noah | none (1 comedy event total in events table, no metrics) | yes (sample) |
| Parking | Marlins @ Mets parking | partial (parking listings exist but not split out) | yes (sample) |
| **NBA** | — | yes (43 events with metrics in 24h) | **MISSING** — need SG event ID |
| **NFL** | — | yes (46 events with metrics in 24h) | **MISSING** — need SG event ID |
| **NHL** | — | partial (1 event in NHL-named bucket) | **MISSING** — need SG event ID |
| **Theater / Broadway** | — | none (events table has no theater rows) | **MISSING** — need SG event ID |

**The gap shape**:
- **EVO side**: theater + comedy categories are essentially dead. Concert tracking has 130 events but only 1 with active metrics — concert metrics cron is broken or not enabled. Worth confirming.
- **SG side**: missing 4 popular categories because our seller catalog doesn't include any tickets for them. To fill, need SG event IDs from Julian or manual SG portal lookup.

**Suggested action**:
1. Julian provides SG event IDs for one upcoming NBA + NFL + NHL + Broadway show (e.g., a Knicks home game, a Giants home game, a Rangers home game, a Hamilton performance).
2. Code re-runs `/v2/listings` against those 4 to complete the matrix.
3. Then design's simulation set has full category parity.

Until then, simulations on the existing 8 are valid for those 8 categories specifically. Don't generalize patterns from MLB-only fan-resale data to NBA/NFL until we confirm.

---

## 4. Three views I want to land before simulations get heavy

These are listed in the mapping doc §5; surfacing them here so you know what's coming:

1. **`unified_listings`** — both sources, one rowset, `tier` column. Discussed above.
2. **`event_category_dimensions`** — pre-joined `events` × `taxonomy_xref` so simulation queries don't re-join taxonomy every time.
3. **`sg_market_summary_by_event`** — per-event aggregations grouped by SG tier. Mirrors `event_metrics` shape but tier-aware. Materialized; refreshed alongside the SG listings cron.

Plus the persistence cron itself: `seatgeek_listings_snapshots` has 0 rows even though the schema is ready. Daily v2 sweep over the 25 events with seller catalogs takes ~30s of cron time and unblocks all of the above.

I'll sequence these ahead of `zone_pricer` (build-order step 1 in your doc) since they're cheap and broaden the simulation surface immediately. Push back if you want zone_pricer first.

---

## 5. Open questions

1. **Cron cadence** for `/v2/listings` ingest — daily is conservative. Some events change rapidly (T-7d for sports). Recommend the same cascading model as EVO (`_listings_cadence_seconds`): closer events poll faster. OK to copy that pattern?
2. **Storage retention** — `seatgeek_listings_snapshots` will grow ~30K rows/day on 25 events. Need a retention policy (90 days? rolling?). For simulation use we want history; for live UI a smaller window is fine.
3. **`unified_listings` view** — should I build it before or after the 4 missing categories are sampled? My take: build it now with the 8 we have; it'll naturally expand when the persistence cron lights up the other categories.

---

## Status

Filed by: code · 2026-05-09
Companion docs: `docs/evo-seatgeek-field-mapping-2026-05-09.md` (full crosswalk), `design/code-reply-seatgeek-v2-listings-2026-05-09.md` (earlier note on /v2 endpoint mechanics). All read-only; no SG writes.
