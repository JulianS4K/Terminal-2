# Undelivered Window — fulfillment ops design (2026-05-08)

> **Audience**: claude design (next session) + Julian (code).
>
> **Mandate (Julian, 2026-05-08)**: design a view that shows all future inventory we've SOLD across EVO / SeatGeek / Vivid / StubHub / etc. but have NOT yet delivered to the buyer. Today this is buried in the API; ops needs a single board.
>
> **Wall**: internal only. Lives inside the broker terminal auth gate.

---

## 0. TL;DR

- **One dense board**: every future-event order that hasn't been delivered yet, all channels in one table, sorted by time-to-event by default.
- **Three KPIs above the fold**: $ at risk, # orders at risk, hold expiries in next hour.
- **Bulk actions per event**: a single Knicks G5 might have 60 SeatGeek orders + 12 EVO orders + 4 Vivid — surface the "deliver all 76 for this event" action so ops doesn't click 76 times.
- **Risk tiers** color-coded by time-to-event: T-0 / T-24h = red, T-72h = amber, T-7d = neutral, > T-7d = dim.
- **Hold-expiry alert** is a separate visual lane — these are time-bombs distinct from "needs delivery." Both belong on the page; both have different action.

---

## 1. Context: what "undelivered" means across channels

Different channels have different fulfillment shapes. The page has to normalize them.

| Channel | Source table | Delivery action | Risk if undelivered |
|---|---|---|---|
| **TEvo (own EVO orders)** | `evo_orders` + `evo_order_items` | mark `eticket_downloaded_at`, push e-ticket | direct customer dispute, EVO penalty |
| **SeatGeek (we listed, SG sold)** | `seatgeek_orders` + `seatgeek_orders_by_event` | upload e-ticket / barcode to SG portal | SG penalty + listing penalty |
| **Vivid / StubHub / TickPick / etc.** | `external_orders` (proposed if not exists) | per-platform fulfillment portal | platform penalty + customer ding |
| **Direct retail (`/shop`)** | `retail_orders` (per parallel-products doc) | email e-ticket via SendGrid | direct customer dispute |
| **Wholesale to other brokers** | `wholesale_orders` (if exists) | hand off file/email | broker relationship |

The page treats all these as one stream with a `channel` column. Each channel's source-of-truth fields get normalized into a common shape:

```
{ order_id, channel, event_id, qty, gross,
  sold_at, deliver_by, hold_expires_at, fulfillment_state,
  has_eticket, eticket_url, listing_id }
```

`fulfillment_state` enum: `pending` (just sold) → `held` (in our possession but not pushed) → `pushing` (in flight) → `delivered` (done) → `failed` (action needed). This view shows everything not in `delivered`.

---

## 2. Page layout

### 2.1 Wireframe — full board

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  UNDELIVERED · across all channels                                  refreshed 14s ago │
│  ┌─KPI STRIP────────────────────────────────────────────────────────────────────┐    │
│  │  $1.42M undelivered  ·  872 orders  ·  ⚠ 14 within T-24h  ·  ⏱ 3 holds <1h │    │
│  │  by channel: EVO 412  ·  SG 318  ·  Vivid 89  ·  SH 41  ·  retail 12         │    │
│  └───────────────────────────────────────────────────────────────────────────────┘    │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  FILTERS                                                                              │
│  Window:  [<24h]  [<72h]  [<7d •]  [<30d]  [all]                                     │
│  Channel: [all •] [EVO] [SG] [Vivid] [SH] [Retail] [Wholesale]                       │
│  State:   [pending •] [held •] [pushing] [failed]                                    │
│  $ ≥:     [—]                                                                         │
│  Search:  [event / order id / buyer]                                                  │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  HOLD EXPIRY · next 4h (separate lane — different action than just delivery)          │
│  ┌──────────────────────────────────────────────────────────────────────────────┐    │
│  │  evo_44218  Knicks G5  3 tix  $987 ea  hold expires 14:32 (00:24)  [Renew]  │    │
│  │  sg_77910   Madonna    2 tix  $145 ea  hold expires 15:01 (00:53)  [Push]   │    │
│  │  evo_44319  Yankees    4 tix  $112 ea  hold expires 17:42 (03:34)            │    │
│  └──────────────────────────────────────────────────────────────────────────────┘    │
├──────────────────────────────────────────────────────────────────────────────────────┤
│  ORDERS · sorted by time-to-event ascending (red T-0/T-24h first)                     │
│  ┌─T─────┬──Event──────────────┬─Channel─┬─Qty─┬──Gross──┬──Sold──┬─State───┬─Action─┐│
│  │ T-1d  │ Knicks vs PHI G5    │ SG      │  2  │  $1,974 │ 5/12   │ held    │[Push]  ││
│  │ T-1d  │ Knicks vs PHI G5    │ SG      │  4  │  $3,940 │ 5/12   │ held    │[Push]  ││
│  │ T-1d  │ Knicks vs PHI G5    │ EVO     │  2  │  $1,910 │ 5/11   │ pending │[Deliver]│
│  │   ⤷ 76 more for this event   →  [Bulk action: Deliver all 76 for Knicks G5]     │ │
│  │ T-2d  │ Yankees vs PIT      │ SG      │  4  │  $448   │ 5/11   │ held    │[Push]  ││
│  │ T-3d  │ Knicks vs PHI G6    │ EVO     │  2  │  $2,280 │ 5/12   │ pending │[Deliver]│
│  │ T-3d  │ Madonna · Brooklyn  │ Retail  │  2  │  $290   │ 5/8    │ held    │[Email] ││
│  │ T-5d  │ Knicks vs PHI G7    │ EVO     │  4  │  $5,840 │ 5/11   │ pending │[Deliver]│
│  │ T-7d  │ Yankees vs LAA      │ Vivid   │  2  │  $164   │ 5/10   │ failed ⚠│[Retry] ││
│  │   ⋯ 854 more rows ⋯                                                            │   │
│  └────────────────────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

Color coding (per row, on the time-to-event cell):
- **T-0 to T-24h**: red background tint, bold timestamp
- **T-24h to T-72h**: amber tint
- **T-72h to T-7d**: neutral (default)
- **>T-7d**: dim

State color (on `state` cell):
- `failed` → red text + ⚠ icon, the loudest signal on the page
- `pushing` → amber pulsing dot (in flight)
- `held` → blue (in possession, action available)
- `pending` → neutral (just sold, no action yet)

### 2.2 Row-detail drawer

Click any row → right-side drawer slides in (~400px) with the order's fulfillment timeline + per-channel action buttons.

```
┌──── DRAWER (right slide-in) ─────────────────┐
│ Order sg_77910 · Madonna Brooklyn 5/13        │
│ Channel: SeatGeek                             │
│ Listing: ...41 lower bowl row 12 seats 5-6    │
│ Buyer: SG-handled                             │
│ Sold: 5/12 14:22  ·  $145 × 2 = $290          │
│ State: held                                   │
│                                                │
│ TIMELINE                                       │
│ 5/12 14:22 — sold (SG)                        │
│ 5/12 14:23 — auto-claimed from inventory       │
│ 5/12 14:25 — e-ticket downloaded from origin   │
│ 5/12 14:25 — held; awaiting push to SG portal  │
│                                                │
│ ACTIONS                                        │
│ [Push to SG]   [Cancel & refund]   [Re-fetch]  │
│                                                │
│ NOTES (free-text, ops can append)              │
│ "TM site flagged the original PDF; trying      │
│  manual upload."                               │
└────────────────────────────────────────────────┘
```

### 2.3 Bulk action — "Deliver all N for event"

When a single event has ≥ 5 undelivered orders across any combination of channels, a `[Bulk action]` row appears under the first one. Clicking opens a confirmation:

```
┌──── BULK CONFIRM ───────────────────────────┐
│ Deliver 76 undelivered orders                │
│ Event: Knicks vs 76ers G5 · 5/13 19:30       │
│                                                │
│ Breakdown                                      │
│   60 SeatGeek (push to portal)                 │
│   12 TEvo (deliver e-ticket)                   │
│    4 Vivid (manual portal upload)              │
│                                                │
│ Estimated time: ~6 min                         │
│ Failures retry: yes                            │
│                                                │
│ [Cancel]  [Run]                                │
└────────────────────────────────────────────────┘
```

Run kicks off a server-side job; shows a progress strip at the top of the page until done.

---

## 3. Backend / API needs

### 3.1 Single normalizing view

```sql
CREATE VIEW public.undelivered_orders_v AS
SELECT order_id, channel, event_id, qty, gross,
       sold_at, deliver_by, hold_expires_at, fulfillment_state,
       has_eticket, eticket_url, listing_id
FROM evo_orders WHERE fulfillment_state <> 'delivered'
UNION ALL
SELECT ... FROM seatgeek_orders WHERE ...
UNION ALL
SELECT ... FROM external_orders WHERE ...
UNION ALL
SELECT ... FROM retail_orders WHERE ...;
```

This is the SINGLE source the undelivered page reads. Adding a new channel = adding a UNION clause + ingesting the channel's order data; the UI doesn't change.

### 3.2 New endpoints

| route | purpose |
|---|---|
| `GET /api/broker/undelivered` | filtered list of undelivered orders |
| `GET /api/broker/undelivered/kpi` | top strip KPIs (count, $, at-risk count) |
| `GET /api/broker/undelivered/holds-expiring?within=4h` | the holds lane |
| `POST /api/broker/undelivered/{order_id}/deliver` | per-order action |
| `POST /api/broker/undelivered/event/{event_id}/bulk-deliver` | the bulk action |
| `GET /api/broker/undelivered/{order_id}/timeline` | drawer timeline data |

All gated to broker auth; reads `undelivered_orders_v`.

### 3.3 Cron / push refresh

- Refresh client every 30s via auto-poll (the freshness chip shows "14s ago"). Don't push WebSocket for v1; polling at 30s is fine for ops scale.
- Server-side cron `refresh_undelivered_kpi` every 60s — the KPI strip queries are expensive enough to want caching.
- Hold-expiry alarm cron: every 5 min, scan for `hold_expires_at < NOW() + 1h` → fire a Slack/email/PagerDuty notification. (Per code's incident-response patterns.)

---

## 4. Simulations — fulfillment scenarios

Scoring: 🟢 = ops resolves the situation in <2 min; 🟡 = needs <10 min; 🔴 = page can't drive the resolution.

| Scenario | Default board | Hold lane | Bulk action | Drawer |
|---|---|---|---|---|
| Single Knicks G5 push to SG | 🟢 (one row, click Push) | n/a | n/a | 🟢 |
| 76 Knicks G5 orders to push (post-cron) | 🔴 (76 clicks) | n/a | 🟢 (one click) | n/a |
| 3 holds expiring < 1h | 🟡 (visible but not loud enough?) | 🟢 (dedicated lane) | n/a | 🟢 |
| Failed Vivid retry | 🟢 (red row) | n/a | n/a | 🟢 (timeline shows error) |
| Pre-game ops sweep — "anything for tonight?" | 🟢 (default sort = T- ascending) | 🟢 | 🟢 | 🟢 |
| Buyer disputes "didn't get my tickets" | 🟡 (search by order id) | n/a | n/a | 🟢 (timeline shows when sent) |
| Channel-wide outage (SG portal down) | 🟢 (filter channel=SG, see queue) | n/a | 🟡 (bulk hits same wall) | 🟢 |
| 1,000-order day | 🟡 (table is dense; pagination needed) | 🟢 | 🟢 | 🟢 |
| Recovery after a fulfillment system crash | 🟡 (need to identify "stuck pushing") | n/a | 🟢 | 🟢 |

**Insights**:
- The bulk action is the highest-leverage feature. Without it, 76-order events crush ops.
- The holds-expiring lane needs to be unmissable. Suggest a fixed pinned banner at the top until the count is zero.
- "Failed" state is rare but high-stakes. Consider a separate FAILURES tab that lists only failed orders with one-click retry — keeps them from getting buried in a 1000-row board.
- Search by order_id is a common buyer-dispute scenario; needs to be a first-class search field, not tucked into filters.

**Surfaced gap**: post-event ops review. After an event ends, the ops team needs to see "of all the orders for Knicks G5, how many were delivered on time vs late vs failed?" That's a different view (reporting / postmortem) than the live undelivered board. Out of scope for this doc but should be a Phase 2 companion page.

---

## 5. Open questions

1. **Polling vs WebSocket** — 30s poll OK for v1 ops scale. Reconsider if order volume scales 10x.
2. **Bulk action atomicity** — if 60 of 76 bulk-deliveries succeed and 16 fail, what's the UX? Suggest: progress strip shows "60/76 delivered, 16 failed"; failed rows turn red on the board; ops handles retries on the failed rows individually.
3. **Stale state** — what counts as "stuck pushing"? Suggest: state=`pushing` AND last_state_change > 10 min → auto-flag as failed and surface for retry. Define this precisely with code/ops together.
4. **Per-event view alongside the global** — when ops works "Knicks G5 push", they want a focused page just for that event's orders. Suggest: clicking the event name in the global board filters to that event; the URL is shareable (`/undelivered?event=3845925`).
5. **Notification channels** — Slack vs email vs PagerDuty? Suggest: PagerDuty for hold-expiry < 30min and channel-wide outage; Slack for everything else; email opt-in only.
6. **Data retention for delivered** — how long do we keep `delivered` orders queryable? Suggest: 90 days hot, archive after. Beyond 90 days, this lives in the reporting/postmortem view.
7. **Wholesale orders in scope?** — if S4K does any wholesale, those need to be on this board. Confirm with code whether `wholesale_orders` exists or is part of EVO/SG already.

---

## 6. Build sequence

| # | Ship | Blockers | Notes |
|---|---|---|---|
| 1 | `undelivered_orders_v` view + `/api/broker/undelivered` | code, ~2d | Foundation. Verify channel coverage. |
| 2 | Default board (rows + sort + filters) | design+code, ~3d | Ship without bulk yet. |
| 3 | Hold-expiry lane | code, ~1d | Pin to top, alarm cron in parallel. |
| 4 | Drawer (timeline + per-order actions) | design+code, ~2d | Reuse existing per-channel deliver actions. |
| 5 | Bulk-deliver-for-event action | code-heavy, ~3d | Server-side job + progress strip. |
| 6 | Search by order_id / buyer | code, ~1d | Index-driven; fast. |
| 7 | Phase 2: post-event reporting view | code+design, ~5d | Out of v1 scope; flag for next planning round. |

---

## 7. References

- Existing: `evo_orders`, `evo_order_items`, `seatgeek_orders`, `seatgeek_orders_by_event` (per `docs/terminal-redesign-2026-05-09.md` §3 Page 6 Order Book).
- Existing: code's redesign memo's Page 6 (Order book / Sales pipeline) — adjacent design that touches some of this.
- Existing: `/api/broker/event/{id}/orders` — per-event order list (subset of what this view aggregates).
- Companion: `design/preliminary-event-views-2026-05-08.md` — broker terminal templates.
- Companion: `design/retail-site-2026-05-08.md` — `retail_orders` is one of the channels that lands here.

---

## 8. Status

Filed by: design · 2026-05-08
Ops-tier view, internal only, gated to broker auth. Designed to scale from current ~hundreds-of-orders to projected thousands without re-architecting.
Next step: review by Julian (code) + claude design session pickup; align with code on the `undelivered_orders_v` columns + per-channel `fulfillment_state` enum.
