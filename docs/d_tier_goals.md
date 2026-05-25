# D-Tier Goals — the destination per lane (DRAFT for operator/lane ratification)

**Author:** B1 (librarian) · **Date:** 2026-05-24 · **Status:** DRAFT — north-stars need operator sign-off; D3 + E1 flagged for owner input.

`PROJECT_BIBLE.md` tracks the project in its **current** form (what exists, who owns it, the rules). This companion answers the other question: **where is each D-lane going, and how do we know when it's arrived?** Goals here are synthesized from [`docs/d_tier_unification_plan.md`](d_tier_unification_plan.md) (milestones M0–M5), the bible's lane scopes, and this session's exos/storefront work — not invented. Correct anything that doesn't match your vision; this is meant to be edited.

---

## The one Jesus moment (what all the lanes converge to)

> **One platform: a fan discovers an event, buys a ticket, and walks through the door with it — while the operator sees the entire market and their position in it, and a venue manages its own event end-to-end — all on the same Supabase core, with each audience seeing only what it should.**

The D-tier isn't six products; it's **layers of one platform**. The unification plan's spine is the path: `land core → shared order model → consumer surface → seller analytics → door → free go-live → paid + distribution`. Each lane below is a layer of that single moment, with its own "you've arrived" test.

The non-negotiable that spans all of them (**G1**): *reuse the components, scope the data per audience.* Brokers see market intelligence; sellers see only their own org; fans see only public + their own wallet. That boundary is what lets one codebase serve all three without leaking across them.

---

## D0 — Terminal FE · the broker's command center

| | |
|---|---|
| **North star** | The operator opens one screen and sees the **whole secondary market** — every event across SeatGeek / TEvo / TickPick / Vivid with live pricing, demand velocity, weather, ESPN/sports context, arbitrage, and blind spots — plus their own position, with pricing actions one click away. The bridge from "we have data" to "we make the call." |
| **Today** | Event / performer / venue pages; `get_broker_event_page_v3` (9 enrichment panels); movers, blind-spots, cross-source metrics; SG sales windows. Email-gated `@s4kent.com`. Consolidated frontend lead (hosts D1/D2 surfaces during test). |
| **Path to there** | Wire pricing **actions** (not just intelligence) → alerting on movers/blind-spots → richer per-event decision surface. (Mostly incremental panel + action work; the data spine exists.) |
| **You've arrived when** | A broker runs their entire trading day from D0 — discovery → decision → action — without dropping to SQL or another tool. |

## D1 — Consumer Retail · the storefront ("DICE-consumer" front door)

| | |
|---|---|
| **North star** | A public, SEO-fronted ticket **storefront** where a fan discovers an event — **primary (our own D4 events) and secondary (TEvo/EVO), deduped by canonical key** — buys, and holds the ticket. The consumer face of the platform. |
| **Today** | Storefront discovery over TEvo/EVO; `/api/store/*`; SEO/discovery front door. Secondary only; no real checkout yet. |
| **Path to there** | Unification-plan **Phase B**: surface primary `exos_public_*` alongside secondary (deduped) → real checkout-from-D1 into the shared core → re-home the wallet + rotating QR → Supabase Auth → primary-vs-secondary CTAs. |
| **You've arrived when** | A fan finds a **D4 event in the storefront**, buys it, and the ticket lands in a wallet whose QR the D4 door scanner accepts. (Free events first; paid when Stripe lands.) |

## D2 — Orders / Ops · the unified order command

| | |
|---|---|
| **North star** | **One model and one dashboard for every order** — broker secondary, our primary, and distributed — with canonical status, fulfillment, reconciliation, and undelivered-order triage. The single source of "what sold, what shipped, what's owed." |
| **Today** | `unified_orders` + canonical status vocab + metrics RPCs + order clients + `/undelivered` + the ops dashboard. Secondary/broker orders today. |
| **Path to there** | Unification-plan **Phase A**: source-tag the order model, land fulfilled **primary** orders into `unified_orders` (`source=exos_primary`), confirm one reporting model aggregates primary + secondary + distributed. |
| **You've arrived when** | Every order, regardless of source, lands in one model with canonical status — sales reporting + reconciliation + undelivered all read it, and a primary purchase shows up next to a broker order automatically. |

## D3 — Broadway scraper · the niche-market data edge *(owner input needed)*

| | |
|---|---|
| **North star** | *(inferred — confirm)* Comprehensive **Broadway + adjacent live-entertainment** inventory/sales coverage feeding the broker model, so D0 has an edge in markets the big firehoses cover poorly. The data-collection arm under D2. |
| **Today** | Scraper, sub-lane of D2. *(B1 has limited visibility into D3's current state — D2/operator to fill in.)* |
| **Path to there** | **TBD — needs D2/operator definition.** Likely: broaden coverage → normalize into the canonical event/sales model → feed D0 intelligence. |
| **You've arrived when** | *(draft)* The Broadway market is fully represented in the canonical model and surfaces in D0 alongside the major sources. **Operator/D2: please refine this lane's goal — it's the one I'm least sure of.** |

## D4 — Exos / Bridge · the primary-market ticketing platform

| | |
|---|---|
| **North star** | A full **primary-market ticketing platform** — a venue/promoter creates an org, builds an event, sells tickets, manages staff, and scans at the door; a fan buys, holds a wallet ticket with a rotating QR, and transfers it safely. Our own "DICE/Eventbrite," off Firebase, on the shared Supabase core. |
| **Today** | Orgs / events / tickets / transfers / check-in / follows / mail on Supabase — **Firebase fully cut over**. Free-first hardening batch (event caps, per-account limits, server-side barcode verify, mail drainer, box-office issuance, follower announce, holder notify) authored + B1-reviewed, **pending A1 apply**. Stripe + distribution scaffolds **dormant by design**. |
| **Path to there** | Unification-plan **Phase 0 → B → C → D**, then the paid/distribution tracks: land the free-first batch → consumer buy-from-D1 → **org-scoped** seller analytics (B1-gated) → physical door rehearsal → **free go-live**; then Stripe (paid) + Automatiq/EVO distribution (each operator-cred + Hard-Rule-2 gated) → **paid go-live**. |
| **You've arrived when** | **M2 (free):** a fan discovers a D4 event, claims a free ticket, the wallet shows a live rotating QR, and the D4 scanner admits it — caps + limits enforced. **M5 (paid):** the same with Stripe checkout + refunds + legal, and inventory distributed to secondary channels. |

## E1 — External Markets · *(future, stub — owner input needed)*

| | |
|---|---|
| **North star** | *(inferred — confirm)* Turn the demand/pricing intelligence into **tradeable positions** — a Kalshi-style event-contract / prediction-market integration layered on the market data the platform already produces. |
| **Today** | Stub lane; not started. |
| **Path to there** | **TBD — future phase.** Gated behind the core platform shipping; depends on the D0 intelligence layer being mature. |
| **You've arrived when** | *(draft)* TBD with operator. |

---

## How to read this with the bible + the plan

- **`PROJECT_BIBLE.md`** = current form (what exists, rules, ownership). Read first, every session.
- **This doc** = destination per lane (the "why" / the moment). Read when you need to know *which direction* a lane's work should push.
- **[`docs/d_tier_unification_plan.md`](d_tier_unification_plan.md)** = the route (phases, milestones M0–M5, dependencies, acceptance). Read when you need *the next concrete step*.

Sequencing reality (from the plan): **D2's order core (Phase A) and D4's free-first launch are the near-term spine; D1 consumer + D0 actions ride on top; D3 + E1 are later.** The whole thing converges on the one Jesus moment above.

---

## Open for ratification

1. **North-star wording per lane** — operator: edit any that don't match your vision.
2. **D3** — its goal is my weakest inference; D2/operator should define it.
3. **E1** — confirm the Kalshi/prediction-market framing + when it activates.
4. Once ratified, B1 adds a one-line pointer from `PROJECT_BIBLE.md §2` to this doc (A1 merges, per the bible refresh policy).
