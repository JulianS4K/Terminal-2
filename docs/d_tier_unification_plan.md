# D-Tier Unification — Implementation Plan (for review)

**Status:** plan for review (no code shipped by this doc).
**Companion:** architecture + audience matrix in [`docs/d_tier_unification_map.md`](d_tier_unification_map.md).
**Author:** D4 · **Date:** 2026-05-23.
**Reviewers:** **C1** (architecture/continuity), **B1** (data-access scoping §3 + payments/distribution surfaces), **D0/A1** (lane re-carve, Render, prod applies), **Operator** (Stripe/Automatiq/SMTP creds + Hard-Rule-2 sign-off).
**Review log:** B1 — **APPROVED** (planning; no code to gate) with 3 build-time bake-ins (bot_chat #474), incorporated below in A.2, §3, C.1, C.4.

---

## 0. Goal & guardrails

Build one platform — **consumer (discover→buy→wallet)** + **seller/venue backend (manage→analytics→scan)** — by **composing existing D-tier layers**, not rebuilding. Two non-negotiables:

- **G1 — Reuse components, scope the data per audience.** Sellers see only their own org's operational data; **broker market intelligence (ESPN/team "Knicks" stats, SG/TEvo firehose, arbitrage) stays operator-only + email-gated** and is never wired to a seller/consumer surface. Cross-org isolation always. (Matrix: map §4.)
- **G2 — Respect the hard rules.** Upstream APIs read-only (secondary distribution + Stripe = gated writes needing operator auth); migrations A1-applied; B1 reviews new auth/data surfaces.

---

## 1. Current state (starting line)

**Already built this session — PR #323 (pending A1 apply + deploy + operator creds):**

| Item | Artifact | State |
|---|---|---|
| Event-level oversell cap | mig `20260523150000` | ready to apply |
| Server-side barcode verify + malformed reject | mig `20260523160000` + client | ready |
| Per-person buy limits (cumulative, 2nd-buy) | mig `20260523180000` + checkout pre-check | ready |
| Mail drainer | `exos-mail-drain` + mig `20260523130000` | ready; needs RESEND key |
| **Stripe paid path (scaffold)** | mig `20260523170000` + `exos-checkout`/`stripe-webhook`/`exos-connect-onboard` + `lib/checkout.ts` | **GATED** (creds + Rule 2) |
| **Distribution (scaffold)** | mig `20260523190000` + `exos-distribute` | **GATED** (Automatiq creds + Rule 2) |

**Merged earlier (#321/#322):** SW scope fix, Realtime multi-lane check-in, CSV fix, load harness.

**Pre-existing, reusable:** D0 charting/KPI widgets (uPlot), D1 consumer discovery, D2 `unified_orders` + canonical status + metrics RPCs + order clients + auth gate, canonical keys (`aq_event_map`/`bridge_event_xref`), `exos_*` core (events/tickets/transfers/checkins) under deny-by-default RLS.

**Net: the commerce/ticket core + door scanner exist (some gated). The unification work is composition + the consumer/seller surfaces + audience-scoped reporting.**

---

## 2. Phases

Each phase lists work items, owner-lane, dependencies, and acceptance. "DONE" = already in PR #323.

### Phase 0 — Land the core (unblocks everything)
| # | Work | Lane | Acceptance |
|---|---|---|---|
| 0.1 | Merge PR #323; A1 applies migs `130000/150000/160000/170000/180000/190000` | A1 | migs live; verified on a schema-carrying branch (preview replay is broken repo-wide) |
| 0.2 | B1 review: `exos_check_in_ticket`, Stripe + distribution surfaces, audience matrix | B1 | sign-off |
| 0.3 | Deploy edge fns (`exos-mail-drain`, checkout, webhook, connect, distribute; webhook `--no-verify-jwt`) + rebuild Bridge → `static/bridge/` | A1/D0 | endpoints reachable |
| 0.4 | Operator: `RESEND_API_KEY`+`EXOS_MAIL_FROM`, Auth SMTP; (Stripe/Automatiq creds when those phases activate) | Operator | mail sends; sign-ins scale |

### Phase A — Shared order/commerce core (backend, low-risk)
| # | Work | Lane | Dep | Acceptance |
|---|---|---|---|---|
| A.1 | Source-tag the order model: generalize `exos_checkout_sessions` line items with `source ∈ {exos_primary, tevo_secondary,…}` + canonical `aq_short_event_id` | D4 | 0.1 | a checkout records source + canonical key |
| A.2 | Land fulfilled **primary** orders into `unified_orders` (source=`exos_primary`) using D2's canonical status vocab. **B1 #474: `unified_orders` ALSO holds broker orders — sellers read it ONLY via an org-scoped SECDEF RPC (C.3), never a raw SELECT. Confirm `unified_orders` has no `anon`/`authenticated` SELECT grant** (one stray grant leaks every broker order to every seller) | D4 + D2 + B1 | A.1 | primary purchase shows in `unified_orders`; no direct seller SELECT on the table |
| A.3 | Reporting reads one model: confirm `d2_metrics_*` (or org-scoped variants, §C.1) can aggregate primary + secondary | D2 | A.2 | one sales model across direct + distributed |
| A.4 | Disallow mixed-source carts (one order = one merchant) | D4 | A.1 | validation enforced |

### Phase B — Consumer surface ("DICE consumer")
| # | Work | Lane | Dep | Acceptance |
|---|---|---|---|---|
| B.1 | D1 discovery surfaces **primary** (`exos_public_events/tiers`) alongside **secondary** (TEvo/EVO), deduped by canonical key | D1 | — | a D4 event appears in the storefront |
| B.2 | Real checkout-from-D1 → shared core (`exos-checkout` for primary). Free/comp works now; paid when Stripe live | D1 + D4 | A.1, 0.3 | fan buys a primary event from D1 |
| B.3 | Wallet + rotating QR in the consumer surface — re-home D4 React buyer views (MyTickets/TicketDetail/WalletPass/Transfer/Claim). **FE decision: React (G-D1 below)** | D4→consumer | B.2 | ticket lands in wallet with live QR |
| B.4 | Supabase Auth in the consumer surface (sign-in to buy/hold; hub same-origin session) | D1/D4 | — | authed buy + persistent wallet |
| B.5 | Event page: "buy direct" (primary) distinct from secondary listings; secondary = deep-link until secondary-fulfillment built | D1 | B.1 | clear primary-vs-secondary CTA |

**Phase B milestone = a fan goes into the consumer surface, finds a D4 event, buys, and holds it in a wallet whose QR the D4 scanner accepts.** (Free events: end-to-end now. Paid: gated on Stripe.)

### Phase C — Seller analytics & console (SCOPED — G1)
| # | Work | Lane | Dep | Acceptance |
|---|---|---|---|---|
| C.1 | Build **org-scoped analytics RPCs** (`exos_org_sales_metrics`, `exos_event_checkin_stats`, `exos_org_orders`, sales-velocity/tickets-sold curve, channel breakdown) — SECDEF + `exos_has_org_role`, **own-org only, zero broker data**. **B1 #474: ship each with `REVOKE EXECUTE … FROM PUBLIC, anon` from day one** (Supabase grants `anon` EXECUTE explicitly; `FROM PUBLIC` alone leaves it — the phase-2 mail lesson). NOT email-gated (sellers aren't `@s4kent`) | D4 | A.2 | RPC returns only caller's org data; `anon` EXECUTE revoked |
| C.2 | Seller dashboard in the D4 console: **reuse D0 uPlot chart + KPI widgets** (wrap in React) + D2 metric patterns, **fed only by C.1 RPCs** | D4 (+D0 widgets) | C.1 | charts render org sales; no broker RPC imported |
| C.3 | Seller orders/fulfillment view from `unified_orders`, org-scoped | D4 (+D2) | A.2 | seller sees own orders, not others' |
| C.4 | **B1 audit (both halves, #474)**: (a) broker RPCs stay `@s4kent.com` email-gated; (b) `exos_org_*` RPCs are org-scoped + `anon`-revoked; (c) `unified_orders` has no raw seller SELECT; (d) cross-org isolation holds | B1 | C.2 | sign-off on all four |

**Phase C milestone = a seller sees their event's sales curve, tickets-sold, check-in rate, and order list — and provably cannot see ESPN/arbitrage data or any other org's data.**

### Phase D — Door & scale
| # | Work | Lane | State |
|---|---|---|---|
| D.1 | Scanner (OrganizerCheckIn) | D4 | DONE |
| D.2 | Realtime multi-lane convergence | D4 | DONE (deploy-pending) |
| D.3 | **Door rehearsal (D4-OPS-11)** — physical, deployed app, 2–3 devices: RPC latency, 1000-row registry, cross-lane convergence, mass sign-in | D4/Op | go/no-go gate |

### Cross-cutting tracks (parallel, gated)
| Track | Work | Gate |
|---|---|---|
| Payments | Stripe scaffold → live (Connect onboarding, checkout, webhook mint) | Operator Stripe creds + counsel'd Terms/Privacy (D1-OPS-5) |
| Distribution | Automatiq/Lysted → EVO scaffold → live (lands inventory in D1 + secondary) | Operator creds + Hard-Rule-2 sign-off |
| Inventory hold | Reservation/hold at checkout — closes the two-tab `maxPerAccount` race + Stripe charged-but-sold-out race + enables refund-on-fail | design + build |
| Refunds | Void → Stripe refund flow + holder notification | Stripe live |
| Email | Drainer deploy + provider | RESEND key |
| Auth SMTP | Custom SMTP for 1000-sign-in spike | Operator |

---

## 3. Data-access scoping (the enforced boundary — G1)

Reuse widgets; scope sources. Build + verify these source boundaries:

| Audience | Allowed sources | Forbidden | Enforcement |
|---|---|---|---|
| Consumer | `exos_public_*` views; own wallet (`exos_tickets` owner/buyer RLS); sanitized public price series | seller internals, broker RPCs, other fans' tickets | RLS + public views |
| **Seller** | own-org `exos_*` (RLS `exos_has_org_role`); **new `exos_org_*` metrics RPCs**; own-org orders via an org-scoped SECDEF RPC over `unified_orders` (never a raw table SELECT) | **broker intelligence RPCs (`get_broker_event_page_v2`, ESPN/SG firehose, arbitrage)**; other orgs | RLS own-org + SECDEF org-scoped RPCs. **Load-bearing wall = the broker RPCs' `@s4kent.com` email-gate** (a seller's non-`@s4kent` JWT is rejected in the RPC body); the FE "don't import broker RPCs" convention is secondary defense-in-depth (B1 #474) |
| Door (scanner) | check-in RPC + own-event scan data (scanner role) | sales $, other events | role-gated RLS |
| Operator/broker | full broker terminal | — | email-gate `@s4kent.com` (existing) |

**New build for scoping:** the `exos_org_*` analytics RPCs (C.1) — so sellers get charts without ever touching broker data. **B1 gate (C.4)** before any seller dashboard ships.

---

## 4. Sequencing / milestones

```
M0 Land core ........ Phase 0            (merge #323, apply, B1, deploy, creds)
M1 Order core ....... Phase A            (backend; one order/reporting model)
M2 Consumer (free) .. Phase B (+B free)  (discover→buy→wallet, free events live)
M3 Seller analytics . Phase C            (scoped dashboards; B1 gate)
M4 Door rehearsal ... Phase D.3          (go/no-go) → FREE-event go-live
M5 Paid + dist live . Payments + Distribution tracks (operator creds + legal) → PAID go-live
```

Dependency spine: **0 → A → B → (C ∥ door) → free go-live → (payments ∥ distribution) → paid go-live.** Phase C can run parallel to consumer once A is done. Door rehearsal gates free launch; Stripe + legal gate paid launch.

---

## 5. Front-end & lane decisions (need a call)

- **G-D1 (FE stack):** standardize consumer + seller surfaces on **D4's React**, wrapping D0/D2 vanilla widgets (uPlot wraps via ref+effect; D2 data is RPC reads); keep **D1 storefront as the SEO/discovery front door**. *Alt:* keep surfaces vanilla, port wallet/QR — only if SEO/perf of server-rendered storefront is required.
- **G-D2 (lane re-carve):** consumer = D1 + D4-buyer; seller = D4 + D0/D2 widgets. Needs D0/A1 coordination; assign an owner for the shared order core (recommend D4-adjacent in the Supabase layer).
- **G-D3 (mixed carts):** disallow initially.
- **G-D4 (consumer price context):** show a sanitized public price series or omit — must not expose broker intel.

---

## 6. Risks

1. **Data leakage across audiences** (the whole point of G1) — mitigated by org-scoped RPCs + B1 gate + RLS; highest-severity, reviewed first.
2. **Gated integrations** (Stripe, Automatiq) inert without operator creds — free-event path must not depend on them.
3. **Migration-replay broken repo-wide** — validate migs on a branch carrying the `exos_*` schema, not the auto preview.
4. **Two FE stacks** — contained by the React-standardization decision; avoid a third.
5. **Scale unproven** — door rehearsal is the gate; DB validated to 1k but not field-tested.
6. **Inventory hold absent** — residual oversell/double-buy races until built.

---

## 7. Definition of done (per milestone)

- **M1:** a primary purchase appears in `unified_orders`; reporting aggregates primary + secondary.
- **M2 (free):** fan discovers a D4 event in the consumer surface, claims a free ticket, wallet shows a rotating QR, D4 scanner admits it; per-person limits + caps enforced.
- **M3:** seller dashboard shows own-org sales/scan analytics; B1 confirms zero broker-data / cross-org exposure.
- **M4:** green door rehearsal on the deployed app.
- **M5:** paid checkout (Stripe) end-to-end with refund path + counsel'd legal; distribution live to EVO/secondary.
