# D-Tier Unification Map — "Toast / DICE for tickets"

**Status:** design / planning (no code shipped by this doc).
**Author:** D4. **Review needed:** C1 (architecture/continuity), **B1 (data-access scoping — §4)**, D0/A1 (lane re-carve + Render).
**Date:** 2026-05-23.

---

## 1. Thesis

The D-tier projects are **not five products — they are the layers of one ticketing
platform**, built lane-by-lane. The backend is already largely unified (all read the
same Supabase Postgres, linked by one canonical event key); the work is **composition
+ front-end consolidation + strict per-audience data scoping** — not new backend.

Shape (DICE-style): a **consumer** app (discover → buy → wallet), a **seller/venue**
backend (manage → analytics → scan), a shared **commerce/ticket core**, and **ingestion**.

---

## 2. The five projects + reusable assets

| Project | Role | Stack | Owns | Standout reusable assets |
|---|---|---|---|---|
| **D0** Terminal FE | Broker/operator analytics terminal | Vanilla JS + **uPlot** | `static/terminal/*` | Charting/reporting engine: uPlot time-series, KPI grids, data tables, freshness/velocity chips, alerts timeline, tab system |
| **D1** Storefront | Consumer discovery | Vanilla JS, no build | `static/store/*`, `/api/store/*` | Consumer UI: event cards, search typeahead, movers sliders, event-detail (zones/sections/listings), quick-pricing rollup, reserve modal (mock) |
| **D2** Orders dashboard | Order/fulfillment ops | Python FastAPI + vanilla JS | `d2_dashboard/*` | Order layer: 5-broker normalizers → **canonical order schema + status vocab**, `unified_orders` view, metrics KPIs/sparklines/sales-gaps, Supabase-JWT auth gate, order clients (`evo/sg/tickpick/vivid/gotickets`, read-only) |
| **D3** Broadway scraper | Inventory ingestion | Python | `broadway_client.py` | Scrape pattern + dedup quantization (minor) |
| **D4** Exos/Bridge | Primary ticketing + seller + scanner | React SPA + `exos_*` + edge fns | `d4_bridge/*`, `exos_*` migs | Commerce/ticket core: events/tiers/mint/checkout(Stripe scaffold)/transfer/void, rotating-QR wallet, **scanner**, distribution scaffold |

---

## 3. Target architecture (composition)

```
CONSUMER ("DICE")                       SELLER ("DICE Partner")              DOOR
─ discovery ...... D1 storefront         ─ event/inventory mgmt . D4 console    ─ scanner . D4
─ price context .. D0 chart widget*      ─ sales/analytics ...... D0 chart+KPI widgets*
─ buy direct ..... shared checkout       ─ orders/fulfillment ... D2 normalizers + unified_orders + metrics*
─ wallet + QR .... D4 buyer views        ─ auth gate ............ D2 require_auth pattern
─ transfer/claim . D4 buyer views
        │                                        │
        └──────────── SHARED CORE (Supabase / Postgres + edge fns) ────────────┘
  identity · events (exos_* + aq_event_map canonical) · orders (unified_orders, extended to
  carry primary) · tickets + barcode contract · checkout/fulfillment · distribution
        │
   INGESTION: secondary firehoses (SG/TEvo/TickPick/Vivid) + D3 scraper + ESPN/weather

  * = REUSE the component, but feed it an AUDIENCE-SCOPED data source (see §4). The widget
      is shared; the data behind it is not.
```

---

## 4. Data-access scoping — audiences & enforcement  ⚠ HARD REQUIREMENT

**Principle: reuse components, scope the data.** A surface inherits a *widget*, never another
audience's *data*. Every surface reads through an audience-scoped RPC/view; no surface calls
another audience's data source. **Event sellers never see broker market intelligence** (ESPN/
team/injury "Knicks stats", the SG/TEvo firehose, cross-source arbitrage/pricing comps) — that
is operator-only and stays email-gated. Sellers see only *their own org's operational data*.

| Data domain | Consumer | Seller (own org) | Door (scanner) | Operator/Broker | Source / enforcement |
|---|---|---|---|---|---|
| Public event catalog (name, venue, time, public tiers/prices) | ✅ | ✅ own | — | ✅ all | `exos_public_*` views (published-only, column-narrowed) + `/api/store` catalog |
| A fan's own tickets / orders / wallet | ✅ own only | ❌ | ❌ | admin only | `exos_tickets` RLS `owner_id/buyer_id = auth.uid()` |
| Org operational data — sales, `tickets_sold`, check-ins, scan-rejects, orders, fulfillment for the org's OWN events | ❌ | ✅ own org | ✅ scanner subset | ✅ (admin/internal) | **new org-scoped RPCs** (`exos_org_*_metrics`) + `exos_*` base tables under `exos_has_org_role` RLS |
| **Broker market intelligence** — ESPN/team/injury stats, SG/TEvo firehose, arbitrage, pricing comps, blind spots | ❌ | ❌ | ❌ | ✅ ONLY | `get_broker_event_page_v2` etc. — **email-gated `@s4kent.com`** (existing). MUST NOT be wired to seller/consumer surfaces |
| Consumer price context (optional "from $X" / public price history) | ✅ sanitized | — | — | ✅ | a **public-safe** price-series RPC (public min/median only) — NOT the broker firehose |
| Cross-org data (other sellers' events/sales) | ❌ | ❌ never | ❌ | ✅ (admin) | RLS `org_id` scoping (deny-by-default; already enforced on `exos_*`) |

**Concrete implication for the seller dashboard:** it reuses D0's uPlot chart + KPI components,
but the price/inventory series is **the org's own sales velocity / tickets-sold-over-time /
check-in rate** from a new `exos_org_*` RPC — *not* `get_broker_event_page_v2` (which carries
ESPN/arbitrage and is operator-gated). Same widget, different — scoped — data.

**Enforcement layers (mostly already present):** (a) RLS deny-by-default + `exos_has_org_role`
own-org on `exos_*`; (b) `owner_id/buyer_id` RLS for consumer wallet; (c) email-gate on broker
RPCs; (d) column-narrowed public views for anon. **Gap to build:** the org-scoped analytics RPCs
(so sellers get charts without touching broker intelligence) + ensuring the seller front-end
never imports a broker RPC. B1 to review the audience matrix before any seller-dashboard wiring.

---

## 5. The unifiers (why it composes)

1. **Shared Supabase Postgres** — D0/D1/D2/D4 already read the same DB. Backend ~unified; fragmentation is front-end only.
2. **Canonical event key** — `aq_event_map.aq_short_event_id` + `bridge_event_xref` + `seatgeek_event_xref` give one event identity across primary + secondary + all surfaces.
3. **`unified_orders` (D2)** — broker-agnostic order ledger + canonical status vocab; extend to also carry **primary (Exos) orders** → one sales/reporting model across direct + distributed.
4. **Barcode/ticket contract** — consumer wallet mints the signed QR; door scanner verifies it server-side. Already decoupled + shared (the consumer↔door seam).

---

## 6. Front-end reality + decision

Three vanilla-JS front-ends (D0, D1, D2) + one React app (D4). uPlot + the D2 metrics are
framework-agnostic and **wrap cleanly into React** (uPlot is imperative — ref + effect), and D2
data is just RPC reads — so D0/D2 components are reusable in D4's React **without a rewrite**.

**Recommended:** standardize the **consumer** and **seller** surfaces on D4's React, wrapping
D0/D2's vanilla widgets; keep **D1's storefront as the SEO/discovery front door** into the
consumer app. (Alt: keep surfaces vanilla and port the wallet/QR — only if SEO/perf of a
server-rendered storefront outweighs reuse.)

---

## 7. Reuse → build, phased

- **Phase A — Shared core:** generalize `exos_checkout_sessions` → source-tagged `orders`; extend `unified_orders` to carry primary; (barcode contract already done). *Backend, low-risk.*
- **Phase B — Consumer:** D1 shows primary (D4 direct) + secondary (EVO) deduped by canonical key; real checkout-from-D1 → shared core; re-home D4 buyer views (wallet/QR) as the consumer app; Supabase auth in the storefront.
- **Phase C — Seller analytics:** wrap D0 chart/KPI widgets + D2 metrics/`unified_orders` into the D4 seller console, **fed only by org-scoped RPCs (§4)**. Build the `exos_org_*_metrics` RPCs.
- **Phase D — Door:** D4 scanner (done) + the rehearsal (D4-OPS-11).

**First slice:** Phase A's source-tagged `orders` + extending `unified_orders` to primary — it's
the connective tissue every other phase leans on, it's backend-only/low-risk, and it makes the
seller's sales reporting and the consumer's order history one model.

---

## 8. Open decisions

1. **FE stack** per surface (recommend React for consumer+seller; D1 stays the discovery front door).
2. **Org-scoped analytics RPCs** — exact metric set for the seller dashboard (sales velocity, tickets-sold curve, check-in rate, channel breakdown) — all org-scoped, no broker data.
3. **Mixed-source carts** — disallow initially (one order = one merchant/source).
4. **Consumer price context** — show a sanitized public price series, or omit? (must not expose broker intel.)
5. **Lane ownership** re-carve (consumer = D1+D4-buyer; seller = D4+D0+D2 components) — D0/A1 coordination.
