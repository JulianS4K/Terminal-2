# D-Tier Goals — the destination per lane

**Author:** B1 (librarian) · **Ratified:** operator 2026-05-24 · **Status:** ratified (lane owners may refine specifics).

`PROJECT_BIBLE.md` tracks the project in its **current** form. This companion answers: **where is each D-lane going, and how do we know when it's arrived?** Operator-ratified 2026-05-24.

---

## The endgame: an open-distribution Ticketmaster

> **Combine every lane into one thing: a Ticketmaster you don't have to be locked inside.** We own **primary ticketing** (venue → event → sale → door, via D4), **distribute that inventory openly** to every channel instead of walling it in, run a **consumer storefront** (D1) on top of it, and steer the whole thing with a **live market-intelligence brain** (D0, fed by D2/D3) — eventually even **trading** the secondary market and **running a betting pool on ticket prices** (E1). Sell like Ticketmaster, trade like nobody else, distribute everywhere.

The six lanes are **layers of that one endgame**, not separate products. The near-term spine (per the unification plan) is D2's sales-data backend + D4's free-first launch; D1 consumer and D0 actions ride on top; D3 + E1 extend it. The non-negotiable across all of it (**G1**): reuse the components, **scope the data per audience** — brokers get market intelligence, sellers get only their own org, fans get only public + their own wallet.

---

## D0 — Terminal FE · analytics & discovery now, the trading desk next

| | |
|---|---|
| **North star** | The market-intelligence brain that becomes a **trading desk** — see any event across all sources with live pricing/demand/context, discover what to act on, and **eventually trade the secondary market from the same screen.** |
| **Today** | Event/performer/venue pages; `get_broker_event_page_v3` (9 panels); movers, blind-spots, cross-source metrics. Email-gated `@s4kent.com`. |
| **Path to there** | **NEXT = analytics + event discovery** (deepen the intelligence + surface what's worth acting on). **THEN = trading** (pricing actions / execution from D0) — trading comes *after* the analytics+discovery layer is solid. |
| **You've arrived when** | *(near)* a broker discovers and fully analyzes any event from D0; *(later)* a broker **trades** from it without leaving the screen. |

## D1 — Consumer Retail · secondary storefront now, D4's discovery engine eventually

| | |
|---|---|
| **North star** | The public **storefront** — near-term **purely secondary**; eventually the **discovery engine for D4** (our own primary inventory), deduped against secondary. |
| **Today** | Storefront discovery over TEvo/EVO; `/api/store/*`; SEO front door. Secondary only. |
| **Path to there** | **NEXT = purely secondary** (discovery + buy on secondary inventory). **EVENTUAL = the discovery engine for D4** — surface and sell D4 primary events alongside secondary (unification-plan Phase B: dedupe by canonical key, real checkout, wallet + rotating QR). |
| **You've arrived when** | *(near)* a fan discovers + buys a secondary ticket; *(eventual)* a fan discovers a **D4 primary event** in the storefront and buys it, ticket landing in a wallet the D4 scanner accepts. |

## D2 — Orders / Ops · the sales-data backend (feeds D0) + broker status test + CS logistics

| | |
|---|---|
| **North star** | The **backend sales/order layer**: (a) **feeds D0** the sales data behind the broker brain; (b) a **status test** brokers glance at to confirm the **sales APIs are up**; (c) **day-over-day sales tracking**; (d) the tool **customer service uses to fill + track order logistics**. Mostly backend — not a customer-facing product. |
| **Today** | `unified_orders` + canonical status vocab + metrics RPCs + order clients + `/undelivered` + the ops dashboard. |
| **Path to there** | Keep feeding D0; sharpen the **sales-API health/up-or-down view**; solidify **day-day sales tracking**; build out **CS fulfillment/logistics** tooling (fill orders, track delivery). Land primary orders into the shared model so day-day sales include D4 (unification-plan Phase A). |
| **You've arrived when** | A broker opens D2 to confirm the sales integrations are live + read day-over-day sales; CS fills + tracks order logistics from it; and D0's intelligence reads D2's data underneath. |

## D3 — Broadway scraper · a data source feeding D0

| | |
|---|---|
| **North star** | A **data-collection source that feeds D0** — extending the broker brain's coverage into markets the big firehoses miss (current focus: Broadway). |
| **Today** | Scraper, sub-lane of D2. |
| **Path to there** | Broaden coverage → normalize into the canonical event/sales model → pipe into D0's intelligence (likely via D2's backend). |
| **You've arrived when** | D3's data shows up in D0 alongside the major sources — the broker sees the niche markets too. |

## D4 — Exos / Bridge · the venue arm + the ticket infrastructure for the storefront

| | |
|---|---|
| **North star** | The **venue/primary arm** *and* the **ticket infrastructure that powers the storefront** — venues/promoters create orgs, build events, sell, manage staff, and scan at the door; the same ticket infra (issue/wallet/rotating-QR/transfer/check-in) backs D1's primary sales. Our own primary-ticketing core, off Firebase, on Supabase. |
| **Today** | Orgs/events/tickets/transfers/check-in/follows/mail on Supabase — **Firebase fully cut over**. Free-first hardening batch (caps, per-account limits, server-side barcode verify, mail drainer, box-office issuance, announce/notify) authored + B1-reviewed, **pending A1 apply**. Stripe + distribution scaffolds **dormant by design**. |
| **Path to there** | Unification-plan **Phase 0 → B → C → D** then paid/distribution: land free-first → **power D1's primary checkout** (D4 infra behind the storefront) → org-scoped seller analytics (B1-gated) → door rehearsal → **free go-live**; then Stripe (paid) + Automatiq/EVO distribution (operator-cred + Hard-Rule-2 gated) → **paid go-live** → **open distribution** (inventory flows to every channel). |
| **You've arrived when** | A venue runs its event on D4, the storefront sells that event's tickets on D4's infra, and the scanner admits the buyer's wallet QR — first free (M2), then paid + distributed everywhere (M5). |

## E1 — External Markets · a ticket-price betting pool (options for tickets)

| | |
|---|---|
| **North star** | Feed the platform's demand/pricing **metrics into a betting market** — a **ticket-price betting pool**: take positions on where ticket prices go. **Options, for tickets.** The market-intelligence brain (D0) becomes tradeable beyond the tickets themselves. |
| **Today** | Stub lane; not started. |
| **Path to there** | Future — depends on the D0 intelligence layer + a clean metrics pipeline being mature enough to price/settle contracts. Likely a Kalshi-style integration or a self-hosted pool. |
| **You've arrived when** | A ticket-price options/betting pool runs off the platform's live metrics — someone takes a position on a ticket price and the pool settles against real data. |

---

## How the lanes converge to the endgame

```
D3 ─┐
    ├─► D2 (sales-data backend, status, CS logistics) ─► D0 (analytics → discovery → trading)
D4 ─┤                                                         │
    └─► D1 (storefront: secondary now → D4 discovery)         └─► E1 (ticket-price betting pool)
         ▲                                                         (options on the metrics)
    D4 ticket infra powers D1 primary sales
                    │
   all of it = OPEN-DISTRIBUTION TICKETMASTER
   (own primary + trade secondary + distribute everywhere)
```

- **`PROJECT_BIBLE.md`** = current form (what exists, rules). Read first, every session.
- **This doc** = destination per lane + the endgame. Read to know *which direction* a lane pushes.
- **[`docs/d_tier_unification_plan.md`](archive/d_tier_unification_plan.md)** = the route (phases, M0–M5, acceptance). Read for *the next concrete step*.

**Near-term spine:** D2 sales-data backend + D4 free-first launch are the foundation; D1 (secondary → D4 discovery) and D0 (analytics → trading) build on top; D3 widens D0's data; E1 is the long-horizon layer on the mature metrics brain.
