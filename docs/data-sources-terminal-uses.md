# Data sources for the terminal — what's new and how to use it

> **Read this before designing any new event-detail / movers / portfolio panel.** Two new data sources landed 2026-05-09. They unlock signals we couldn't expose before. Backend is already wired; UI is the bottleneck.

This memo is for both lanes:
- **design** (live now, terminal frontend) — concrete UI suggestions are in §3 and §5.
- **copilot** (paused) — when copilot returns to retail/chatbot work, sections §4 and §6 cover how these sources show up in the chatbot retrieval layer (NOT in chatbot responses — same product-wall rule applies).

---

## 1. The data wall — quick recap

```
                    BROKER (full)                RETAIL (S4K-owned only)
Pricing
  TEvo asks         ✓ all listings               ✓ S4K listings only
  TEvo orders (NEW) ✓ S4K's order book           ✗ never — leaks brokerage state
  SeatData sales    ✓ market-wide history        ✗ never — competitor data
  SeatData stats    ✓ fill rate, get-in          ✗ derived only

ESPN context        ✓ inline                     used in retrieval only
Wiki / NOAA         ✓ inline                     used in retrieval only
```

**Never cross the wall.** EVO orders include buyer + seller + client identity → broker only. SeatData sales include competitor brokerage data → broker only.

---

## 2. SeatData — what's new

**What it is**: second pricing source. SeatData scrapes secondary marketplaces (StubHub primarily) and exposes a different cut than TEvo:
- `sd_sales_normalized` — historical **sold listings** (transacted prices). TEvo doesn't expose this.
- `seatdata_event_stats` — pricing time series with **listing fill rate** (sold / total ever listed) and multi-marketplace get-in.

**API surface** (all under `/api/seatdata/*`):

| route | charge | purpose |
|---|---|---|
| `GET /account` | free | identity + plans + rate limits |
| `GET /usage` | free | billing-period totals (server-side) |
| `GET /budget` | free | DB-tracked pull budget (100/day, 2000/month hard cap) |
| `GET /event/{tevo_event_id}` | free | xref status + persisted snapshot counts |
| `GET /event/{tevo_event_id}/sales` | free | read 0–5000 persisted sales rows + summary |
| `POST /event/{tevo_event_id}/auto-search` | free | search SeatData by date+venue and link if matched |
| `POST /event/{tevo_event_id}/link?sd_event_id=` | free | manual xref |
| `POST /event/{tevo_event_id}/sync-sales` | **PAID 1 pull** | pull `/v0.3/salesdata/get` and persist new rows |

**Key key**: stored in Supabase Vault as `SEATDATA_API_KEY`. App reads it via `public.get_app_secret('SEATDATA_API_KEY')` — no Railway env var needed. Rotation: `SELECT vault.update_secret(<id>, '<new-key>')`.

**ID mismatch caveat**: TEvo and SeatData use different ids for everything.

| concept | TEvo id | SeatData id | mapping table |
|---|---|---|---|
| event | `events.id` | `event_id` | `seatdata_event_xref` |
| venue | `venues.id` | `std_venue_id` | `seatdata_venue_xref` |
| performer/tour | `performers.id` | `std_event_id` | `seatdata_performer_xref` |
| zone | curated/derived | inline string | `seatdata_zone_xref` (per event) |
| section | inline | inline | `seatdata_section_xref` (per event) |

**Use the view, not the raw table** — `sd_sales_normalized` joins through the xref system and gives you canonical zone/section names. It also handles the **quantity-null caveat**: SeatData returns `quantity=0` to mean "unknown" (not literally 0); the view surfaces that as NULL with a `quantity_unknown` flag.

```sql
-- Quick example: average sale by canonical zone (Knicks G5)
SELECT canonical_zone, COUNT(*) AS n, ROUND(AVG(price)::numeric, 2) AS avg_sale
FROM sd_sales_normalized
WHERE tevo_event_id = 3345925 AND quantity IS NOT NULL
GROUP BY canonical_zone ORDER BY n DESC;
```

---

## 3. SeatData — UI uses (design lane)

### A. Sales overlay on the chart workbench
Add `SeatData_Sales` as a new togglable series. Each historical sale = one scatter dot:
- **x** = sale_timestamp
- **y** = price ($-axis, same as TEvo medians)
- **color** = canonical_zone (8 colors max, group "unmapped" as gray)
- **size** = quantity (when known) or fixed small (when unknown)
- **hover** = `$price · qty (or "unknown qty") · section · row · canonical_zone`

This is the **most actionable** addition since the chart workbench itself: brokers price against transacted comps, not asks. Knicks G5 (TEvo `3345925`) is pre-populated with 254 rows for visual testing.

### B. "Sales tape" mini-panel on event hero
Below the price KPIs, a compressed scrolling tape:
> `2h ago · $720 · qty 2 · 200 Level §210` `5h ago · $1066 · qty 6 · 100 Level §114` …

Pull from `GET /api/seatdata/event/{id}/sales?limit=20`. If `inactive_excluded` from event lifecycle, hide entirely.

### C. Bid/ask spread analytics
TEvo gives ask, SeatData gives sold price. Compute live:
```
TEvo retail_median  = $988    (current asks)
SeatData median     = $668    (recent transacted)
Spread              = +47.9%  (asks are 48% over sold)
```
This number tells brokers: **am I priced inside the actual transaction band, or am I dreaming?**

### D. Fill-rate badge
When `seatdata_event_stats.listing_fill_rate` is high (>0.7), the market is moving — green tag. Low (<0.3) = market is sticky — red tag. Surface on event hero.

### E. Sync button + budget meter
Manual "Refresh sales" button on the event page. Disable + tooltip when `/api/seatdata/budget` says exhausted. Show `X / 100 today · Y / 2000 month` in a tiny status row.

### F. Splash for unlinked events
When `/api/seatdata/event/{id}` returns `linked: false`, show a "Match this event to SeatData" button that POSTs `/auto-search`.

---

## 4. EVO orders — what's new (NEW)

**What it is**: the brokerage's own order book. TEvo `/v9/orders` returns S4K's pending/accepted/rejected/completed sales + purchases. Pulled every 10 min via cron `evo-orders-collect-10min` (jobid 40), persisted to `evo_orders` + `evo_order_items` with event_id mapped on every line.

**Schema**:

| table | purpose | row grain |
|---|---|---|
| `evo_orders` | order header — state, totals, buyer/seller/client, timestamps | one per `evo_order_id` |
| `evo_order_items` | line items mapped to events + ticket_groups | one per `evo_item_id` |
| `evo_orders_by_event` (view) | rollup: pending/accepted/rejected/completed counts + tickets sold + gross | one per `event_id` |

**API surface**:

| route | charge | purpose |
|---|---|---|
| `POST /api/admin/collect-orders` | TEvo: free; bounded 50 pages × 10 = 500 orders/tick | cron-driven; manual override allowed |
| `GET /api/broker/event/{event_id}/orders` | free | persisted orders + items + summary for an event |

**Order states** (per TEvo docs):

| state | meaning |
|---|---|
| `pending` | Submitted; seller hasn't acted |
| `accepted` | Seller accepted |
| `rejected` | Seller rejected |
| `completed` | Delivered (shipped or e-tickets uploaded) |
| `pending_substitution` | Rejected by fulfilling broker, awaiting substitute |

**Type filter is case-sensitive.** `Order` = sale. `PurchaseOrder` = buy. Anything else returns all.

---

## 5. EVO orders — UI uses (design lane)

### A. Order-book strip on event hero
A compact horizontal bar broken into 5 segments showing pending / accepted / rejected / completed / pending_sub counts. Click → side panel with the actual rows.

```
┌─────────────────────────────────────────────────────────────┐
│ ORDERS    pending: 3   accepted: 12   rejected: 2   completed: 47   sub: 0 │
└─────────────────────────────────────────────────────────────┘
```

Hide if `summary.total_items == 0`.

### B. New default chart series: `EVO_Orders_Completed`
Bar chart on `yC` axis. Bucket by hour. Shows the actual rate-of-sale through S4K, the purest signal of demand for our specific inventory.

Also useful: `EVO_Orders_Pending` as a leading indicator — when pending count spikes and accepted lags, it means buyers are committing but the seller (us) hasn't acted yet.

### C. Sales velocity vs market
Combine SeatData sales rate (whole market) with EVO completed orders (our share):
```
Market sale rate  = 254 sales / 42 days = 6.0 sales/day  (SeatData)
S4K sale rate     =   8 orders /  7 days = 1.1 sales/day  (EVO)
S4K share         = ~18%
```
Surface this on event hero as "market share badge".

### D. Owned position with realized pnl
On the portfolio page, augment `owned_tickets_count` with realized state:
- **Listed** (in inventory, no order)
- **Pending** (buyer committed, awaiting our acceptance)
- **Sold pending fulfillment** (accepted, not yet delivered)
- **Sold complete** (delivered)
- **Refunded** (rejected/refunded)

This is a 5-bucket waterfall per event — much richer than today's "owned vs market" line.

### E. E-ticket fulfillment alerts
If `evo_order_items.eticket_available = true AND eticket_downloaded_at IS NULL` for an order whose event is within 48h, surface as a red alert: "URGENT: 3 unprocessed e-ticket orders for tonight". Top of dashboard.

### F. Hold-expiry urgency
If `evo_orders.hold_expires_at < NOW() + 1h`, badge it as "HOLD EXPIRING". The whole point of holds is to act before they expire.

### G. Realized vs ask price comparison
For every sold order line, compare `evo_order_items.price` (what we sold for) to `listings_snapshots.retail_price` at the time of sale (what we were asking). The delta is realized vs ask, the most honest measure of pricing accuracy.

---

## 6. Retail-side notes (copilot lane, when it returns)

EVO orders are **broker-only data**. Never expose buyer/seller/client identity through chat tool responses. The retail side gets none of this.

SeatData has two safe uses for retail:
- **Demand ranking signal** — events with high SeatData fill rate (>0.5 active) bubble up in retail search results when otherwise ranked equally on price.
- **"Hot ticket" badge** — if SeatData shows >50 sales in last 24h for an event in our inventory, retail UI can show a "🔥 high demand" tag without exposing the source.

Both go in `s4k_popularity_boost` retrieval — same pattern as ESPN's role today.

---

## 7. Quick query cheat sheet

```sql
-- Has SeatData seen any sales for this event in the last 24h?
SELECT COUNT(*) FROM sd_sales_normalized
WHERE tevo_event_id = $1 AND sale_timestamp >= NOW() - INTERVAL '24 hours';

-- Avg sale price by canonical zone for an event
SELECT canonical_zone, ROUND(AVG(price)::numeric, 2) AS avg, COUNT(*) AS n
FROM sd_sales_normalized
WHERE tevo_event_id = $1 AND quantity IS NOT NULL
GROUP BY canonical_zone ORDER BY avg DESC;

-- EVO orders rollup for an event
SELECT * FROM evo_orders_by_event WHERE event_id = $1;

-- "How fast is our inventory turning?" — completed orders per day
SELECT date_trunc('day', o.evo_updated_at)::date AS day,
       SUM(oi.quantity) AS tickets_completed,
       SUM(oi.quantity * oi.price) AS gross
FROM evo_orders o
JOIN evo_order_items oi ON oi.evo_order_id = o.evo_order_id
WHERE oi.event_id = $1 AND o.state = 'completed'
GROUP BY 1 ORDER BY 1 DESC LIMIT 30;

-- "Where's the spread?" — ask vs sold for an event
WITH asks AS (
  SELECT retail_median FROM event_metrics
  WHERE event_id = $1 ORDER BY captured_at DESC LIMIT 1
),
sold AS (
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY price) AS sold_med
  FROM sd_sales_normalized
  WHERE tevo_event_id = $1 AND sale_timestamp >= NOW() - INTERVAL '14 days'
)
SELECT a.retail_median AS ask_median, s.sold_med AS sold_median,
       ROUND(((a.retail_median - s.sold_med) / s.sold_med * 100)::numeric, 1) AS spread_pct
FROM asks a, sold s;
```
